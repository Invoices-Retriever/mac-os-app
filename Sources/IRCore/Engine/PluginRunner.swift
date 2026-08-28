import Foundation

/// Runs one plugin against one source, from sign-in to documents.
///
/// The shape of a run is fixed and short: check whether the persisted session
/// still works; if not, sign in — visibly, with the user present, because that
/// is what 2FA requires; then list documents. Everything else is policy about
/// what to do when a step fails, and that policy is the interesting part.
public struct PluginRunner: Sendable {
    public let manifest: PluginManifest
    public let sessionFactory: any BrowserSessionFactory
    public let vault: CredentialVault
    public let logger: RedactingLogger

    /// F2.6. A run that hangs is worse than a run that fails: it holds a slot
    /// in the scheduler and the user has no idea what is happening.
    public var runBudget: Duration = .seconds(300)
    /// How long we will wait for a person to finish signing in.
    public var interactiveSignInBudget: Duration = .seconds(300)

    /// Called the moment the engine hands over to the user, with the page as it
    /// stood. Reported then rather than at the end of the run: a diagnostic you
    /// can only read once you are unstuck is no use while you are stuck.
    public var onHandOver: (@Sendable (String) async -> Void)?

    public init(manifest: PluginManifest,
                sessionFactory: any BrowserSessionFactory,
                vault: CredentialVault,
                logger: RedactingLogger = .shared) {
        self.manifest = manifest
        self.sessionFactory = sessionFactory
        self.vault = vault
        self.logger = logger
    }

    public struct Outcome: Sendable {
        public var status: RunStatus
        public var documents: [CollectedDocument]
        public var exposedOptions: [ExposedOption]
        public var error: (any Error)?
        public var screenshot: Data?
        /// What the page was made of when it failed. A screenshot shows what it
        /// looked like; this is what a selector is written against.
        public var outline: String?
    }

    public enum Mode: Sendable {
        /// Sign in, with the window visible, and stop. UC-01 and UC-03.
        case authenticateOnly
        /// Collect, without ever showing a window. Fails with `needsSignIn`
        /// rather than interrupting the user mid-batch.
        case collect
        /// Discover the options a source offers, for the setup screen.
        case discoverOptions
    }

    public func run(source: Source,
                    mode: Mode,
                    runID: UUID = UUID(),
                    observer: (any StepObserver)? = nil) async -> Outcome {

        guard manifest.isSupportedByEngine() else {
            return Outcome(status: .failed, documents: [], exposedOptions: [],
                           error: IRError.engineTooOld(required: manifest.engine,
                                                       current: PluginManifest.engineVersion.description))
        }

        // The budget covers what the engine does, not what the person does.
        // A sign-in that waits for someone to fetch their phone must not eat
        // the time getDocuments will need afterwards, so the deadline is a
        // reference the interactive wait pushes forward.
        // The browser belongs to the source, not to this run: it is created
        // once by the factory and kept, because a portal's sign-in usually
        // lives in session cookies that no data store persists. A run hides the
        // window when it is done and leaves the session alone.
        let deadline = Deadline(runBudget.seconds)
        var session: (any BrowserSession)?
        /// The page as it was when the engine handed over to the user.
        var handOverOutline: String?

        do {
            // One keychain read for the whole source; the codes are derived
            // from the seeds already in hand rather than fetched again.
            let secrets = source.rememberCredentials
                ? try vault.secrets(for: source, manifest: manifest)
                : [:]
            let totpCodes = source.rememberCredentials
                ? try vault.totpCodes(from: secrets, manifest: manifest)
                : [:]

            let context = ExecutionContext(
                source: source, manifest: manifest, runID: runID,
                config: source.config, secrets: secrets, totpCodes: totpCodes,
                incrementalCutoff: source.incrementalCutoff())

            let policy = manifest.domainPolicy
            let created = try await sessionFactory.makeSession(sourceID: source.id, policy: policy)
            session = created

            let executor = StepExecutor(session: created, context: context, policy: policy,
                                        deadline: deadline, logger: logger, observer: observer)

            await created.setVisible(mode == .authenticateOnly)

            // --- Is the stored session still good? --------------------------
            let signedIn = await isSignedIn(executor: executor, session: created)
            logger.info(signedIn ? "session is still valid" : "session is not valid",
                        source: source.id, run: runID)

            if !signedIn {
                switch mode {
                case .collect:
                    // F3.4: do not hijack the user's screen in the middle of a
                    // batch. Report it and let the other sources finish.
                    throw IRError.authenticationRequired(source.displayName)
                case .authenticateOnly, .discoverOptions:
                    // checkAuth has just told us where an unauthenticated visit
                    // ends up. That host is the portal's sign-in flow, and it
                    // is the one place we must not navigate while the user is
                    // working — see `signIn`.
                    let signInHost = await created.currentURL()?.host?.lowercased()
                    try await signIn(executor: executor, session: created, context: context,
                                     source: source, runID: runID, deadline: deadline,
                                     signInHost: signInHost, handOverOutline: &handOverOutline)
                }
            }

            // --- Do the work ------------------------------------------------
            switch mode {
            case .authenticateOnly:
                await created.setVisible(false)
                return Outcome(status: .succeeded, documents: [], exposedOptions: [],
                               error: nil, outline: handOverOutline)

            case .discoverOptions:
                if let steps = manifest.getConfigOptions {
                    try await executor.run(steps, section: "getConfigOptions")
                }
                return Outcome(status: .succeeded, documents: [],
                               exposedOptions: context.exposedOptions, error: nil)

            case .collect:
                await created.setVisible(false)
                try await executor.run(manifest.getDocuments, section: "getDocuments")
                return Outcome(status: .succeeded, documents: context.documents,
                               exposedOptions: context.exposedOptions, error: nil)
            }

        } catch {
            // F2.8: a screenshot at the moment of failure is the single most
            // useful thing for fixing a broken plugin. It stays on this
            // machine; nothing uploads it, ever.
            let screenshot = try? await session?.captureScreenshot()
            // A failure is more informative than the hand-over, so it wins.
            let outline = (try? await session?.captureDOMOutline()) ?? handOverOutline
            let status: RunStatus
            if let irError = error as? IRError, irError.needsUserSignIn {
                status = .needsSignIn
            } else if error is CancellationError {
                status = .cancelled
            } else {
                status = .failed
            }
            logger.error("run failed: \(error.localizedDescription)", source: source.id, run: runID)
            await session?.setVisible(false)
            return Outcome(status: status, documents: [], exposedOptions: [],
                           error: error, screenshot: screenshot, outline: outline)
        }
    }

    // MARK: - Authentication

    /// True when a field `startAuth` typed into is still on the page.
    ///
    /// Cheap and non-destructive: it asks the page what it contains rather than
    /// navigating anywhere.
    private func isStillOnSignInForm(session: any BrowserSession) async -> Bool {
        let selectors = (manifest.startAuth ?? [])
            .filter { $0.action == .type }
            .compactMap(\.selector)
        guard !selectors.isEmpty else { return false }

        for selector in selectors {
            let present = (try? await session.evaluate(DOMScripts.exists(selector)))?.boolValue ?? false
            if present { return true }
        }
        return false
    }

    private func isSignedIn(executor: StepExecutor, session: any BrowserSession) async -> Bool {
        do {
            try await executor.run(manifest.checkAuth, section: "checkAuth")
            return true
        } catch {
            return false
        }
    }

    private func signIn(executor: StepExecutor,
                        session: any BrowserSession,
                        context: ExecutionContext,
                        source: Source,
                        runID: UUID,
                        deadline: Deadline,
                        signInHost: String?,
                        handOverOutline: inout String?) async throws {

        await session.setVisible(true)

        if let steps = manifest.startAuth {
            do {
                try await executor.run(steps, section: "startAuth")
            } catch {
                // A failed startAuth is not fatal on its own. Portals move
                // their login forms constantly, and the user is sitting right
                // there and can finish by hand — which is a much better outcome
                // than telling them the plugin is broken.
                logger.warning("automatic sign-in did not complete: \(error.localizedDescription)",
                               source: source.id, run: runID)
            }
        }

        // Whether it is safe to ask the expensive question.
        //
        // `isSignedIn` runs checkAuth, and checkAuth begins by navigating. Ask
        // it while the user is somewhere in the portal's sign-in flow and that
        // page is gone — reported as "the credentials are filled in, then
        // nothing happens and the page reloads", which is precisely what it
        // looks like from the other side of the screen.
        //
        // Checking only for the login form is not enough: a submitted form
        // becomes a two-factor prompt, which has none of its fields, and
        // navigating away from *that* loses a code the user just fetched from
        // their phone. The whole flow lives on the host an unauthenticated
        // visit was redirected to, so that host is the thing to stay off.
        @Sendable func inSignInFlow() async -> Bool {
            if let signInHost, await session.currentURL()?.host?.lowercased() == signInHost {
                return true
            }
            // Belt and braces for a portal that signs you in without leaving
            // the page: the fields startAuth typed into are still on screen.
            return await isStillOnSignInForm(session: session)
        }

        if await inSignInFlow() {
            logger.debug("still inside the sign-in flow; not navigating away from it",
                         source: source.id, run: runID)
        } else if await isSignedIn(executor: executor, session: session) {
            return
        }

        logger.info("waiting for you to finish signing in", source: source.id, run: runID)

        // The moment automation gave up and a person had to step in is the one
        // most worth recording: it is where startAuth stops matching the portal.
        // A two-factor screen the plugin does not recognise looks exactly like
        // this, and without the page's structure the next guess at a selector is
        // as blind as the last.
        handOverOutline = try? await session.captureDOMOutline()
        if let handOverOutline, !handOverOutline.isEmpty {
            await onHandOver?(handOverOutline)
        }

        let startedWaiting = Date()
        let signInDeadline = Date().addingTimeInterval(interactiveSignInBudget.seconds)
        let succeeded = await session.waitForUserSignIn(until: signInDeadline) {
            // Cheap and non-destructive while the user is still working; the
            // real check only once they have left the sign-in flow.
            if await inSignInFlow() { return false }
            return await isSignedIn(executor: executor, session: session)
        }
        // Give back every second the person took. Otherwise a slow two-factor
        // code leaves no budget for the collection it was meant to unlock.
        await deadline.extend(by: Date().timeIntervalSince(startedWaiting))

        guard succeeded else {
            throw IRError.authenticationFailed(
                "sign-in to \(source.displayName) was not completed in time")
        }
        logger.info("signed in", source: source.id, run: runID)
    }
}
