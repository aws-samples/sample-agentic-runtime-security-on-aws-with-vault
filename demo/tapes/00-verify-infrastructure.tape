Output demo/out/term-00.mp4

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

# Deploy Foundation › Verify Infrastructure (workshop page 33) — verbatim.
# One script confirms every foundation module: EKS cluster + nodes + addons, RDS
# status + pgaudit + encryption, Bedrock KB + data sources + retrieval, the
# KMS-encrypted audit log groups, and the canonical-region contract.
Sleep 700ms
Type "bash infrastructure/scripts/test-foundation.sh"
Enter
Sleep 30s
Sleep 2500ms
