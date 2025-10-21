{ pkgs }:

pkgs.dockerTools.buildImage {
  name = "openbao-backup";
  tag = "latest";

  copyToRoot = pkgs.buildEnv {
    name = "openbao-backup-env";
    paths = [ pkgs.openbao pkgs.restic pkgs.jq pkgs.bash ];
  };

  config = {
    Cmd = [
      "/bin/bash"
      "-c"
      # The script is passed as a single string argument to bash -c
      ''
        set -e

        echo "Starting OpenBao backup..."

        # The credentials are provided as environment variables by the CSI driver

        # 1. Take snapshot
        SNAPSHOT_FILE="/tmp/bao-snapshot.snap"
        echo "Taking snapshot to $SNAPSHOT_FILE..."
        bao operator raft snapshot save $SNAPSHOT_FILE

        # 2. Backup with restic
        echo "Backing up with restic..."
        restic backup $SNAPSHOT_FILE

        # 3. Prune old backups
        echo "Pruning old backups..."
        restic forget \
          --keep-daily ''${KEEP_DAILY:-7} \
          --keep-weekly ''${KEEP_WEEKLY:-4} \
          --keep-monthly ''${KEEP_MONTHLY:-6} \
          --prune

        echo "Backup complete."
      ''
    ];
  };
}