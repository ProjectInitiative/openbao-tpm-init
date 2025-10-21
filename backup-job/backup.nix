
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

        # 1. Authenticate to OpenBao using Kubernetes auth
        echo "Authenticating to OpenBao..."
        export BAO_TOKEN=$(bao auth -method=kubernetes role=backup -format=json | jq -r .auth.client_token)

        # 2. Fetch S3 and restic credentials from OpenBao
        echo "Fetching credentials from OpenBao..."
        CREDS=$(bao kv get -format=json secret/backup/restic | jq .data.data)
        export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r .aws_access_key_id)
        export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r .aws_secret_access_key)
        export RESTIC_REPOSITORY=$(echo $CREDS | jq -r .restic_repository)
        export RESTIC_PASSWORD=$(echo $CREDS | jq -r .restic_password)

        # 3. Take snapshot
        SNAPSHOT_FILE="/tmp/bao-snapshot.snap"
        echo "Taking snapshot to $SNAPSHOT_FILE..."
        bao operator raft snapshot save $SNAPSHOT_FILE

        # 4. Backup with restic
        echo "Backing up with restic..."
        restic backup $SNAPSHOT_FILE

        # 5. Prune old backups
        echo "Pruning old backups..."
        restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

        echo "Backup complete."
      ''
    ];
    Env = [
      "BAO_ADDR=http://openbao:8200"
    ];
  };
}
