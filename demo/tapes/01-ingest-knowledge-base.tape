Output demo/out/term-01.mp4

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
Type "export AWS_PAGER=''"
Enter
Sleep 200ms
Type "clear"
Enter
Sleep 600ms
Show

# Deploy Foundation › Ingest Knowledge Base (workshop page 34) — verbatim.
# deploy-workshop.sh already triggered ingestion; this page confirms it completed.
# Resolve the Knowledge Base id directly, then list each data source's last
# ingestion job — every line should read COMPLETE.
Sleep 700ms
Type "KB_ID=$(aws bedrock-agent list-knowledge-bases --region us-east-1 --query 'knowledgeBaseSummaries[?name==`workshop-kb`].knowledgeBaseId | [0]' --output text)"
Enter
Sleep 3s
Type 'echo "KB_ID=$KB_ID"'
Enter
Sleep 1500ms
Type `for DS in $(aws bedrock-agent list-data-sources --knowledge-base-id "$KB_ID" --region us-east-1 --query 'dataSourceSummaries[].dataSourceId' --output text); do echo "=== Data source $DS ==="; aws bedrock-agent list-ingestion-jobs --knowledge-base-id "$KB_ID" --data-source-id "$DS" --region us-east-1 --query 'ingestionJobSummaries[0].[status,startedAt]' --output text; done`
Enter
Sleep 10s
Sleep 2500ms
