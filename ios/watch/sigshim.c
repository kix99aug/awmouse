// watchOS traps inside libsystem's sigaction rather than returning an error,
// which kills the Go runtime in initsig before anything of ours runs. The
// symbol is renamed in the archive to point here instead.
//
// Reporting success is the right lie: the runtime only checks for failure,
// and every handler it wants is one it can live without. It loses SIGSEGV
// translation, so a nil dereference inside Go becomes a crash rather than a
// panic, and it loses SIGURG preemption, so a goroutine spinning without a
// function call is never interrupted. The tunnel blocks on I/O throughout,
// which is a preemption point.
int awsigactn(int sig, const void *act, void *oact) {
    (void)sig; (void)act; (void)oact;
    return 0;
}
