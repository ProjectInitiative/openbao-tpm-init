
{ pkgs }:

let
  backupScript = pkgs.writeShellScript "backup.sh" ''
    #!/bin/bash
    set -e

    echo "Starting OpenBao backup..."

    # 1. Authenticate to OpenBao using Kubernetes auth
    echo "Authenticating to OpenBao..."
    export BAO_TOKEN=$(bao auth -method=kubernetes role=backup -format=json | jq -r .auth.client_token)

    # 2. Fetch S3 credentials from OpenBao
    echo "Fetching S3 credentials from OpenBao..."
    S3_CREDS=$(bao kv get -format=json secret/backup/s3 | jq .data.data)
    export AWS_ACCESS_KEY_ID=$(echo $S3_CREDS | jq -r .aws_access_key_id)
    export AWS_SECRET_ACCESS_KEY=$(echo $S3_CREDS | jq -r .aws_secret_access_key)

    # 3. Configure AWS CLI
    echo "Configuring AWS CLI..."
    aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
    aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY

    # 4. Take snapshot
    SNAPSHOT_FILE="/tmp/bao-snapshot-$(date +%Y-%m-%d-%H-%M-%S).snap"
    echo "Taking snapshot to $SNAPSHOT_FILE..."
    bao operator raft snapshot save $SNAPSHOT_FILE

    # 5. Upload to S3
    S3_BUCKET=${S3_BUCKET:-"openbao-backups"}
    echo "Uploading snapshot to s3://$S3_BUCKET/..."
    aws s3 cp $SNAPSHOT_FILE s3://$S3_BUCKET/

    echo "Backup complete."
  '';

in pkgs.dockerTools.buildImage {
  name = "openbao-backup";
  tag = "latest";

  config = {
    Cmd = [ "${backupScript}" ];
    Env = [
      "PATH=${pkgs.lib.makeBinPath [ pkgs.openbao pkgs.aws-cli pkgs.jq ]}"
      "BAO_ADDR=http://openbao:8200"
    ];
  };
}
