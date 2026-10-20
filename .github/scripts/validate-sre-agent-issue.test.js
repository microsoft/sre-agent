const test = require("node:test");
const assert = require("node:assert/strict");
const validateIssue = require("./validate-sre-agent-issue");
const { validateIssueBody } = validateIssue;

const validBody = `## Agent name

production-agent

## Azure subscription ID

12345678-1234-1234-1234-123456789abc

## Thread ID (required for thread-related issues)

50f7521d-dfee-487e-9188-5abdc8adde91

## Issue description

The agent has failed every investigation since September 19.

## Customer impact

Fully blocked - no workaround

## Workaround

None

## Steps to reproduce

1. Open the production agent in the portal.
2. Submit the example investigation prompt.

## Screenshots

![error](https://github.com/user-attachments/assets/example)

## Expected behavior

The investigation should complete.

## Actual behavior

The investigation fails with an error.

## Sensitive data check

- [x] I have removed or redacted credentials, tokens, customer data, and other secrets from this report and its screenshots.`;

test("accepts a complete issue", () => {
  assert.deepEqual(validateIssueBody(validBody), []);
});

test("reports every required section for an empty issue", () => {
  assert.equal(validateIssueBody("").length, 10);
});

test("requires at least two numbered reproduction steps", () => {
  const body = validBody.replace(
    "1. Open the production agent in the portal.\n2. Submit the example investigation prompt.",
    "The investigation failed.",
  );

  assert.match(validateIssueBody(body).join("\n"), /two clear, numbered/);
});

test("requires an embedded screenshot", () => {
  const body = validBody.replace(
    "![error](https://github.com/user-attachments/assets/example)",
    "Screenshot unavailable",
  );

  assert.match(validateIssueBody(body).join("\n"), /Attach at least one image/);
});

test("allows a missing thread ID for issues unrelated to thread behavior", () => {
  const body = validBody.replace(
    "50f7521d-dfee-487e-9188-5abdc8adde91",
    "",
  );

  assert.deepEqual(validateIssueBody(body), []);
});

test("requires a thread ID when reporting thread behavior", () => {
  const body = validBody
    .replace("50f7521d-dfee-487e-9188-5abdc8adde91", "")
    .replace(
      "The investigation fails with an error.",
      "The conversation thread loses its message history.",
    );

  assert.match(validateIssueBody(body).join("\n"), /Thread ID.*thread-related/);
});

test("mentions the author and applies the question label", async () => {
  let addedLabels;
  let commentBody;
  let failure;
  const github = {
    paginate: async () => [],
    rest: {
      issues: {
        listComments: async () => [],
        getLabel: async () => ({}),
        addLabels: async ({ labels }) => {
          addedLabels = labels;
        },
        createComment: async ({ body }) => {
          commentBody = body;
        },
      },
    },
  };
  const context = {
    repo: { owner: "microsoft", repo: "sre-agent" },
    payload: {
      issue: {
        number: 123,
        body: "",
        labels: [],
        user: { login: "issue-author" },
      },
    },
  };
  const core = {
    setFailed: (message) => {
      failure = message;
    },
  };

  await validateIssue({ github, context, core });

  assert.deepEqual(addedLabels, ["question"]);
  assert.match(commentBody, /@issue-author/);
  assert.match(commentBody, /Please edit the issue/);
  assert.match(failure, /10 required item/);
});
