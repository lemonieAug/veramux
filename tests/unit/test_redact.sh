#!/usr/bin/env bash
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/harness.sh"
source "$ROOT_DIR/lib/redact.sh"
# lib/redact.sh sets -e for production use; turn it back off for this test file.
set +e

SAFETY="$ROOT_DIR/policies/safety.yaml"

DIFF='diff --git a/src/app.js b/src/app.js
index abc..def 100644
--- a/src/app.js
+++ b/src/app.js
@@ -1,2 +1,3 @@
 line1
+line2
diff --git a/.env b/.env
index 111..222 100644
--- a/.env
+++ b/.env
@@ -1 +1 @@
-OLD_SECRET=abc
+NEW_SECRET=supersecretvalue
diff --git a/config/credentials.json b/config/credentials.json
index 333..444 100644
--- a/config/credentials.json
+++ b/config/credentials.json
@@ -1 +1 @@
-{}
+{"key":"leak"}
diff --git a/id_rsa b/id_rsa
index 555..666 100644
--- a/id_rsa
+++ b/id_rsa
@@ -1 +1 @@
--BEGIN--
+-----BEGIN OPENSSH PRIVATE KEY-----'

OUT="$(printf '%s' "$DIFF" | redact_diff "$SAFETY")"

assert_contains "$OUT" "+line2" "non-sensitive file content passes through"
assert_not_contains "$OUT" "supersecretvalue" ".env content is never forwarded"
assert_contains "$OUT" "diff --git a/.env b/.env" ".env filename is still visible"
assert_contains "$OUT" "[REDACTED: sensitive file excluded from review]" ".env is marked redacted"
assert_not_contains "$OUT" '"key":"leak"' "credentials.json content is never forwarded"
assert_not_contains "$OUT" "BEGIN OPENSSH PRIVATE KEY" "id_rsa content is never forwarded"

report_and_exit
