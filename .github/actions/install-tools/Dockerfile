# The tools the shared workflows run, pinned: each stage is a tool's official
# image, by tag and digest. Never built. pinned-tool.sh, beside this file, reads
# it -- to copy a binary out of its image onto the runner (`# path:` above a
# stage says where the binary is), or to hand an image reference to something
# that runs it as a container -- and Dependabot keeps it current, proposing the
# new tag and digest together.
#
# A repository pins its own tools the same way, in a file of its own (say
# .github/tools/Dockerfile), and passes it to install-tools as
# `pins`. Either way the pins file is the one place each version lives, but for
# cosign's: cosign checks the signatures these pins name, so it can't be checked
# by them, and stays a checksummed release binary (../install-cosign).
#
# A digest fixes an image's bytes, as a checksum fixes a download's -- but says
# nothing about who published them. In March 2026 an attacker with Aqua's
# credentials published a malicious trivy release (GHSA-69fq-xp46-6x23), and a
# pin that a bot moves to each new release would have proposed it. So:
#   - Dependabot waits a week before proposing a release (its cooldown, in
#     dependabot.yml), long enough for most hijacked ones to be pulled.
#   - Where the vendor signs its images, `# signed-by: IDENTITY ISSUER` above
#     the stage makes pinned-tool.sh verify that signature (with cosign) before
#     taking anything from the image. {tag} in IDENTITY stands for the stage's
#     tag, so the signature has to come from that version's own release run.
#     That answers stolen registry credentials, not a hijacked release
#     workflow, which signs what it is given; the cooldown and review are what
#     stand between that and CI.
# Neither image here is signed, so for them the digest, the cooldown and review
# are all there is.
#
# The binaries in these images are the vendors' own image builds, not always
# byte-identical to the files on their release pages; each was checked to
# report its version when it was pinned.

# path: /usr/bin/gitleaks
FROM zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f AS gitleaks

# path: /usr/local/bin/actionlint
FROM rhysd/actionlint:1.7.12@sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667 AS actionlint
