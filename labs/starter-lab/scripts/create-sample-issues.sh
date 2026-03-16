#!/bin/bash
# =============================================================================
# Create Sample Customer Issues for Grubify App
#
# Creates 5 realistic customer-reported issues with [Customer Issue] prefix.
# These simulate real user complaints — the issue-triager will classify,
# label, and comment on them.
#
# Requires: GITHUB_PAT (or GITHUB_PAT_VALUE) with 'repo' scope
#
# Usage:
#   export GITHUB_PAT=<your-github-pat>
#   ./scripts/create-sample-issues.sh [owner/repo]
# =============================================================================
set -uo pipefail

REPO="${1:-${GITHUB_REPO:-}}"
PAT="${GITHUB_PAT:-${GITHUB_PAT_VALUE:-}}"

if [ -z "$REPO" ]; then
  echo "Usage: $0 <owner/repo>"
  echo "  or: export GITHUB_REPO=owner/repo && $0"
  exit 1
fi

if [ -z "$PAT" ]; then
  echo "Error: GITHUB_PAT not set"
  exit 1
fi

API="https://api.github.com/repos/${REPO}/issues"
AUTH="Authorization: token ${PAT}"

create_issue() {
  local title="$1"
  local body="$2"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$API" \
    -H "$AUTH" \
    -H "Content-Type: application/json" \
    -d "{\"title\": \"$title\", \"body\": \"$body\"}")
  if [ "$HTTP_CODE" = "201" ]; then
    echo "   ✅ $title"
  else
    echo "   ⚠️  HTTP $HTTP_CODE: $title"
  fi
}

echo ""
echo "📝 Creating sample customer issues in ${REPO}..."
echo ""

create_issue \
  "[Customer Issue] App crashes when adding items to cart" \
  "Hi, I'm trying to add items to my cart on the Grubify app but it keeps crashing. I get a server error after adding about 5-6 items quickly. The page just shows a generic error message.\\n\\nThis started happening today around 3pm. Can someone look into this?"

create_issue \
  "[Customer Issue] Menu page is loading very slowly" \
  "The restaurants page is taking forever to load. It used to be instant but now it takes 10-15 seconds.\\n\\nI'm on a good internet connection so I don't think it's on my end. Is there something wrong with the server?"

create_issue \
  "[Customer Issue] Can't place an order - getting 500 error" \
  "When I click Place Order I get an Internal Server Error. I've tried multiple times with different items. My cart has items in it but the order just won't go through.\\n\\nPlease fix this ASAP, I'm hungry!"

create_issue \
  "[Customer Issue] Feature request - add search for restaurants" \
  "It would be great if I could search for restaurants by name or cuisine type instead of scrolling through the whole list.\\n\\nCan you add a search bar to the restaurants page?"

create_issue \
  "[Customer Issue] How do I clear my cart?" \
  "I added some items to my cart by mistake and I can't figure out how to remove them. Is there a way to clear the cart or remove individual items? I don't see a delete button anywhere."

echo ""
echo "✅ Created 5 sample customer issues in ${REPO}"
echo "   Run the triage scheduled task to classify them!"
