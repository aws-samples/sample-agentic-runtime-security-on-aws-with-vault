Output demo/out/term-06b.mp4

Set Shell "zsh"
Set FontFamily "Meslo LG S DZ for Powerline"
Set FontSize 18
Set Width 1280
Set Height 720
Set Padding 20
Set Margin 40
Set MarginFill "#0d1117"
Set Theme "Dracula"
Set TypingSpeed 20ms

Hide
Type "PROMPT='%F{81}ars%f %F{212}❯%f '"
Enter
Sleep 300ms
Type "source demo/demo-helpers.sh"
Enter
Sleep 500ms
Type "clear"
Enter
Sleep 600ms
Show

# Stitched audit beat — pins to the EXACT request_id the viewer just saw on the
# banking-UI chat output at the end of the UC3 take. Same id, same row.
Sleep 700ms
Type `REQUEST_ID=__REQUEST_ID__`
Enter
Sleep 1500ms
Type 'echo "request_id: ${REQUEST_ID}"'
Enter
Sleep 2500ms

# The audit_correlation VIEW stitches IVIA-decision + Vault-audit + Postgres-audit
# on that single request_id — one row proves: who approved (jaime), which agent
# authenticated (jwt-jaime), the bound claims Vault enforced (may_act / rar_type),
# the DB write, and the 300s credential TTL.
Type `athena_record "SELECT request_id, substr(approval_time,1,19) AS approval_time, user_approved_sub, ciba_binding_message, substr(vault_auth_time,1,19) AS vault_auth_time, vault_principal, vault_path, vault_bound_claim_may_act, vault_bound_claim_rar_type, substr(db_write_time,1,19) AS db_write_time, db_command, db_credential_ttl FROM workshop_logs.audit_correlation WHERE request_id = '${REQUEST_ID}' LIMIT 1"`
Enter
Sleep 18s
Sleep 2500ms
