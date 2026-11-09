const VALID_SUBSCRIPTION_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SCREENSHOT_PATTERN = /!\[[^\]]*]\((?:https?:\/\/|\/)[^)]+\)|<img\b[^>]*\bsrc=["'][^"']+["'][^>]*>|https:\/\/github\.com\/user-attachments\/assets\//i;
const CUSTOMER_IMPACT_OPTIONS = new Set([
  "Fully blocked - no workaround",
  "Blocked - workaround available",
  "Degraded but not blocked",
  "Not customer-blocking",
]);

function getSection(body, heading) {
  const escapedHeading = heading.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = body.match(new RegExp(`(?:^|\\n)## ${escapedHeading}[ \\t]*\\r?\\n([\\s\\S]*?)(?=\\r?\\n## |$)`, "i"));
  return match ? match[1].trim() : "";
}

function isPlaceholder(value) {
  return !value || /^(?:n\/?a|not provided|tbd|todo|\.\.\.)$/i.test(value.trim());
}

function validateIssueBody(body = "") {
  const errors = [];
  const agentName = getSection(body, "Agent name");
  const subscriptionId = getSection(body, "Azure subscription ID");
  const threadId = getSection(body, "Thread ID (required for thread-related issues)");
  const description = getSection(body, "Issue description");
  const customerImpact = getSection(body, "Customer impact");
  const workaround = getSection(body, "Workaround");
  const reproductionSteps = getSection(body, "Steps to reproduce");
  const screenshots = getSection(body, "Screenshots");
  const expectedBehavior = getSection(body, "Expected behavior");
  const actualBehavior = getSection(body, "Actual behavior");
  const sensitiveDataCheck = getSection(body, "Sensitive data check");

  if (isPlaceholder(agentName)) {
    errors.push("Provide the **Agent name**.");
  }
  if (!VALID_SUBSCRIPTION_ID.test(subscriptionId)) {
    errors.push("Provide the **Azure subscription ID** as a valid GUID.");
  }
  if (isPlaceholder(description) || description.length < 30) {
    errors.push("Expand the **Issue description** to explain when the problem started and how often it occurs.");
  }
  if (!CUSTOMER_IMPACT_OPTIONS.has(customerImpact)) {
    errors.push("Select the **Customer impact**, including whether the customer is blocked.");
  }
  if (isPlaceholder(workaround)) {
    errors.push('Describe the current **Workaround**, or enter "None" if no workaround exists.');
  }

  const numberedSteps = reproductionSteps
    .split("\n")
    .filter((line) => /^\s*\d+[.)]\s+\S/.test(line));
  if (numberedSteps.length < 2) {
    errors.push("Provide at least two clear, numbered **Steps to reproduce**.");
  }
  if (!SCREENSHOT_PATTERN.test(screenshots)) {
    errors.push("Attach at least one image in **Screenshots** (drag and drop the image into the field).");
  }
  if (isPlaceholder(expectedBehavior)) {
    errors.push("Describe the **Expected behavior**.");
  }
  if (isPlaceholder(actualBehavior)) {
    errors.push("Describe the **Actual behavior**, including exact errors where possible.");
  }
  const behaviorDetails = `${description}\n${reproductionSteps}\n${actualBehavior}`;
  if (/\b(?:thread|chat|conversation|message history)\b/i.test(behaviorDetails) && isPlaceholder(threadId)) {
    errors.push("Provide the SRE Agent portal **Thread ID** for this thread-related issue.");
  }
  if (!/- \[[xX]] I have removed or redacted credentials/.test(sensitiveDataCheck)) {
    errors.push("Confirm the **Sensitive data check** after removing or redacting sensitive information.");
  }

  return errors;
}

async function run({ github, context, core }) {
  const issue = context.payload.issue;
  const owner = context.repo.owner;
  const repo = context.repo.repo;
  const issueNumber = issue.number;
  const validationMarker = "<!-- sre-agent-issue-validation -->";
  const needsInfoLabel = "question";
  const errors = validateIssueBody(issue.body);

  const comments = await github.paginate(github.rest.issues.listComments, {
    owner,
    repo,
    issue_number: issueNumber,
    per_page: 100,
  });
  const validationComment = comments.find(
    (comment) => comment.user?.type === "Bot" && comment.body?.includes(validationMarker),
  );

  if (errors.length === 0) {
    const labels = issue.labels.map((label) => (typeof label === "string" ? label : label.name));
    if (labels.includes(needsInfoLabel)) {
      await github.rest.issues.removeLabel({
        owner,
        repo,
        issue_number: issueNumber,
        name: needsInfoLabel,
      });
    }
    if (validationComment) {
      await github.rest.issues.deleteComment({
        owner,
        repo,
        comment_id: validationComment.id,
      });
    }
    return;
  }

  try {
    await github.rest.issues.getLabel({ owner, repo, name: needsInfoLabel });
  } catch (error) {
    if (error.status !== 404) {
      throw error;
    }
    await github.rest.issues.createLabel({
      owner,
      repo,
      name: needsInfoLabel,
      color: "D876E3",
      description: "Further information is requested",
    });
  }

  await github.rest.issues.addLabels({
    owner,
    repo,
    issue_number: issueNumber,
    labels: [needsInfoLabel],
  });

  const body = `${validationMarker}
@${issue.user.login}, thanks for reporting this issue. Please edit the issue and add the following details so we can investigate:

${errors.map((error) => `- ${error}`).join("\n")}

The \`${needsInfoLabel}\` label will be removed automatically after all required details are provided. Please redact credentials, customer data, and other sensitive information from text and screenshots.`;

  if (validationComment) {
    await github.rest.issues.updateComment({
      owner,
      repo,
      comment_id: validationComment.id,
      body,
    });
  } else {
    await github.rest.issues.createComment({
      owner,
      repo,
      issue_number: issueNumber,
      body,
    });
  }

  core.setFailed(`Issue is missing ${errors.length} required item(s).`);
}

module.exports = run;
module.exports.validateIssueBody = validateIssueBody;
