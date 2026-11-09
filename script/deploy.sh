#!/usr/bin/env bash
# Deploy miyamints from a release checkout only, and record what was deployed.
#
#   script/deploy.sh [forge script args...]        e.g. --rpc-url ... --account miyamints-deployer --sender 0x... --broadcast --verify
#   DEPLOY_TAG=v1.0.0 script/deploy.sh ...          deploy a release tag instead of main (HEAD must be exactly that tag)
#
# Refuses unless:
#   - the whole repo is clean (no staged, unstaged or untracked files; ignored files are fine),
#   - submodules are checked out at the commits the repo records,
#   - HEAD is `main` and equals origin/main (after a fetch), or HEAD is exactly the tag in DEPLOY_TAG.
# Then runs DeployMiyamints with FOUNDRY_PROFILE=deploy and DEPLOY_GIT_COMMIT / DEPLOY_GIT_REF set; the script refuses
# to broadcast without them and writes both, with the chain id, into deployments/<chainId>.json.
set -euo pipefail

cd "$(dirname "$0")/.."            # contracts/
ROOT="$(git rev-parse --show-toplevel)"

die() { echo "deploy.sh: $*" >&2; exit 1; }

if [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=normal)" ]; then
  git -C "$ROOT" status --short >&2
  die "working tree is not clean: commit or remove these first"
fi

if git -C "$ROOT" submodule status --recursive | grep -qE '^[-+U]'; then
  git -C "$ROOT" submodule status --recursive | grep -E '^[-+U]' >&2
  die "submodules are missing or not at the recorded commits: git submodule update --init --recursive"
fi

COMMIT="$(git rev-parse HEAD)"
if [ -n "${DEPLOY_TAG:-}" ]; then
  TAG_COMMIT="$(git rev-parse -q --verify "refs/tags/${DEPLOY_TAG}^{commit}")" || die "no tag ${DEPLOY_TAG}"
  [ "$TAG_COMMIT" = "$COMMIT" ] || die "HEAD ${COMMIT} is not tag ${DEPLOY_TAG} (${TAG_COMMIT}): git checkout ${DEPLOY_TAG}"
  REF="$DEPLOY_TAG"
else
  BRANCH="$(git symbolic-ref --short -q HEAD || true)"
  [ "$BRANCH" = "main" ] || die "deploy from main only (HEAD is '${BRANCH:-detached}'), or set DEPLOY_TAG to a release tag"
  git fetch -q origin main || die "could not fetch origin/main to confirm this is the released main"
  [ "$(git rev-parse origin/main)" = "$COMMIT" ] || die "local main ${COMMIT} != origin/main $(git rev-parse origin/main): pull or push first"
  REF="main"
fi

echo "deploy.sh: deploying ${REF} @ ${COMMIT}"
export FOUNDRY_PROFILE=deploy DEPLOY_GIT_COMMIT="$COMMIT" DEPLOY_GIT_REF="$REF"
exec forge script script/DeployMiyamints.s.sol "$@"
