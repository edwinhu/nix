#!/bin/bash
sed -i 's/"CLAUDE_CODE_DISABLE_1M_CONTEXT": "1"/"CLAUDE_CODE_DISABLE_1M_CONTEXT": os.environ.get("DISABLE_1M", "1")/g' ~/.local/lib/claude-proxy-launcher.sh
sed -i 's/"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "95"/"CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": os.environ.get("PCT_OVERRIDE", "90")/g' ~/.local/lib/claude-proxy-launcher.sh

sed -i '/CLAUDE_CODE_DISABLE_1M_CONTEXT=1 \\/d' ~/.local/lib/claude-proxy-launcher.sh
sed -i '/CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=95 \\/d' ~/.local/lib/claude-proxy-launcher.sh

sed -i 's/CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \\/if [ "$PROVIDER_NAME" = "Codex" ]; then\n    DISABLE_1M=1\n    PCT_OVERRIDE=$PCT\nelse\n    DISABLE_1M=0\n    PCT_OVERRIDE=90\nfi\n\nDISABLE_1M=$DISABLE_1M \\\nPCT_OVERRIDE=$PCT_OVERRIDE \\\nCLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \\/g' ~/.local/lib/claude-proxy-launcher.sh
