# Security

BHops Optimizer can apply privileged Windows and adapter changes. Review the code and use release checksums before running it. Release binaries currently have no code-signing certificate.

For a vulnerability, use this repository's GitHub private vulnerability reporting. If it is unavailable, open an issue requesting a private contact channel without exploit details. Public issues should omit exploit details and local diagnostic identifiers until a fix is available.

The current supported release is v0.1.x. Driver installation is restricted to reviewed manifests. The application does not accept arbitrary downloaded scripts, registry targets, driver URLs, or commands from a backup/job request. Jobs and backups reject unrecognized schemas, unsupported targets, mismatched identity, and symbolic-link/junction paths.
