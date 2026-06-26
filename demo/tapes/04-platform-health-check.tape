Output demo/out/term-04.mp4

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

# Deploy Foundation › Platform Health Check (workshop page 38) — verbatim.
# One script rolls up the whole platform layer: Vault (pods, seal, peers, audit),
# IVIA pods + OIDC issuer, cert-manager, and the AWS Load Balancer Controller —
# eight checks, all PASS, before moving on to the use cases.
Sleep 700ms
Type "bash infrastructure/scripts/test-vault-verify.sh"
Enter
Sleep 10s
Sleep 2500ms
