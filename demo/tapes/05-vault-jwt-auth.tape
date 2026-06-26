Output demo/out/term-05.mp4

Set Shell "zsh"
Set FontFamily "Meslo LG S DZ for Powerline"
Set FontSize 18
Set Width 1280
Set Height 720
Set Padding 20
Set Margin 40
Set MarginFill "#0d1117"
Set Theme "Dracula"
Set TypingSpeed 18ms

# Use Case 2 › Vault JWT Authentication (workshop page 62) — all five steps,
# verbatim. The only off-camera setup is the JWT itself: page 62 has the attendee
# sign in to the Banking UI as oscar and copy the HttpOnly `id_token` cookie from
# DevTools. demo/capture-uc2-jwt.sh produces that exact token reproducibly; it is
# sourced here as JWT_TOKEN, standing in for the attendee's browser paste.
#
# The Vault token that Step 5's login returns (which the attendee copies into
# VAULT_TOKEN for the creds read) is captured here off-camera and then `clear`ed
# from the buffer, so only the verbatim page commands show on camera.
Hide
Type "PROMPT='%F{81}ars%f %F{212}❯%f '"
Enter
Sleep 300ms
Type "source demo/out/uc2-jwt.env"
Enter
Sleep 300ms
Type `VAULT_TOKEN=$(kubectl exec -n vault vault-0 -- vault write auth/jwt/login role=uc2-jwt jwt="$JWT_TOKEN" -format=json | jq -r .auth.client_token)`
Enter
Sleep 4s
Type "clear"
Enter
Sleep 600ms
Show

# Step 1 — load the root token, inspect the jwt auth backend config.
Sleep 700ms
Type "export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)"
Enter
Sleep 800ms
Type `kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read auth/jwt/config"`
Enter
Sleep 5s
# Step 2 — the uc2-jwt role: bound_audiences=agent-uc2, user_claim=sub.
Type `kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read auth/jwt/role/uc2-jwt"`
Enter
Sleep 5s
# Step 3 — the uc2-personal policy: read-only DB creds, no write role reachable.
Type `kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault policy read uc2-personal"`
Enter
Sleep 5s
# Step 4 — the database role: 15m TTL, SELECT-only on the banking schema.
Type `kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault read database/roles/uc2-personal-readonly"`
Enter
Sleep 5s
# Step 5 — live jwt login with the user's JWT; token_meta_user_sub proves Vault
# extracted sub=oscar from the token. Then use the returned Vault token to fetch
# the per-user JIT database credential (15m TTL, username bound to the sub).
Type `kubectl exec -n vault vault-0 -- vault write auth/jwt/login role=uc2-jwt jwt="${JWT_TOKEN}"`
Enter
Sleep 5s
Type `kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=${VAULT_TOKEN} vault read database/creds/uc2-personal-readonly"`
Enter
Sleep 4s
Sleep 2500ms
