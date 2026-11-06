import { defineRailway, github, project, service } from "railway/iac";
// This repository manages only its own resources in the environment. Other
// repositories export their own partial name.
// See https://docs.railway.com/infrastructure-as-code#multi-repo-projects
export const partial = "angelic-elegance";
export default defineRailway(() => {
  const angelicElegance = service("angelic-elegance", {
    source: github("richard4801/Claude-Template", { branch: "claude/ecstatic-rubin-2egjfb", checkSuites: false, rootDirectory: "/server/api" }),
    build: { buildEnvironment: "V3", builder: "DOCKERFILE", dockerfilePath: "Dockerfile" },
    healthcheck: "/health",
    healthcheckTimeout: 60,
    replicas: { "sfo": 1 },
  });

  return project("sunny-friendship", {
    variables: { managed: false },
    resources: [angelicElegance],
  });
});
