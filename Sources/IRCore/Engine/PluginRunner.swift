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
        let deadline = Deadline(runBudget.seconds)
        var session: (any BrowserSession)?

        do {
            let secrets = source.rememberCredentials
                ? try vault.secrets(for: source, manifest: manifest)
                : [:]
            let totpCodes = source.rememberCredentials
                ? try vault.totpCodes(for: source, manifest: manifest)
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
                    try await signIn(executor: executor, session: created, context: context,
                                     source: source, runID: runID, deadline: deadline)
                }
            }

            // --- Do the work ------------------------------------------------
            switch mode {
            case .authenticateOnly:
                return Outcome(status: .succeeded, documents: [], exposedOptions: [], error: nil)

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
            let outline = try? await session?.captureDOMOutline()
            let status: RunStatus
            if let irError = error as? IRError, irError.needsUserSignIn {
                status = .needsSignIn
            } else if error is CancellationError {
                status = .cancelled
            } else {
                status = .failed
            }
            logger.error("run failed: \(error.localizedDescription)", source: source.id, run: runID)
            return Outcome(status: status, documents: [], exposedOptions: [],
                           error: error, screenshot: screenshot, outline: outline)
        }
    }

    // MARK: - Authentication

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
                        deadline: Deadline) async throws {

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

        if await isSignedIn(executor: executor, session: session) { return }

        logger.info("waiting for you to finish signing in", source: source.id, run: runID)
        let startedWaiting = Date()
        let signInDeadline = Date().addingTimeInterval(interactiveSignInBudget.seconds)
        let succeeded = await session.waitForUserSignIn(until: signInDeadline) {
            await isSignedIn(executor: executor, session: session)
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
