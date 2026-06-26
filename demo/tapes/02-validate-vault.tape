Output demo/out/term-02.mp4

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
Type "clear"
Enter
Sleep 600ms
Show

# Deploy Foundation › Validate Vault (workshop page 35) — verbatim.
# Load the root token (written to ~/vault-init.json at deploy), then confirm the
# 3-node Raft HA cluster is Running, KMS auto-unsealed, with all peers and an
# audit device enabled.
Sleep 700ms
Type "export VAULT_ROOT_TOKEN=$(jq -r '.root_token' ~/vault-init.json)"
Enter
Sleep 800ms
Type "kubectl get pods -n vault"
Enter
Sleep 3s
Type "kubectl exec -n vault vault-0 -- vault status"
Enter
Sleep 5s
Type `kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault operator raft list-peers"`
Enter
Sleep 3s
Type `kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN='${VAULT_ROOT_TOKEN}' vault audit list"`
Enter
Sleep 3s
Sleep 2500ms
