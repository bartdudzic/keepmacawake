import Darwin

/// Metadata rules shared by the privileged reader and nonprivileged tests.
public enum ServiceFileValidation {
    public enum Kind {
        case persistent
        case heartbeat
    }

    public static func isSafe(_ metadata: stat, owner: uid_t, kind: Kind) -> Bool {
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == owner, metadata.st_mode & 0o022 == 0 else { return false }
        switch kind {
        case .persistent:
            return metadata.st_nlink == 1
        case .heartbeat:
            // Atomic replacement can unlink an already opened, immutable beat.
            // Its descriptor still names the checked inode; freshness is checked
            // after decoding. Multiple links are never accepted.
            return metadata.st_nlink == 0 || metadata.st_nlink == 1
        }
    }
}
