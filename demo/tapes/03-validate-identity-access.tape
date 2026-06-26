Output demo/out/term-03.mp4

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

# Deploy Foundation › Validate Identity Access (workshop page 36) — verbatim.
# IBM Verify Identity Access runs as a seven-pod stack. Confirm all pods Running +
# autoconf Completed, the WRP ALB Ingress, OIDC discovery through the public WRP
# junction, and the same issuer reached over the in-cluster ClusterIP service.
# (The recovery-only block on page 36 deletes working state — skipped here.)
Sleep 700ms
Type "kubectl get pods -n verify-access"
Enter
Sleep 3s
Type "kubectl get ingress -n verify-access"
Enter
Sleep 3s
Type 'source infrastructure/.acme-state && WRP_HOST="$NIP_FQDN_WRP" && echo "WRP host: $WRP_HOST"'
Enter
Sleep 1500ms
Type 'curl -sk "https://$WRP_HOST/isvaop/oauth2/.well-known/openid-configuration" | jq .issuer'
Enter
Sleep 3s
Type "kubectl run oidc-check --image=curlimages/curl --rm -i --restart=Never --quiet -n verify-access -- curl -sk https://iviaop.verify-access.svc.cluster.local:8436/oauth2/.well-known/openid-configuration </dev/null | jq .issuer"
Enter
Sleep 40s
Sleep 2500ms
