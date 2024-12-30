# Bash automation script for simplified deployment of https://github.com/cloudflare/serverless-registry 

Prerequisites:
- A Cloudflare account (find and copy account ID). 
- Activated Cloudflare R2 subscription
- A Cloudflare API token with the following permissions: 
  - `Account:Workers R2 Storage:Edit`
  - `Account:Workers KV Storage:Edit`
  - `Account:Workers Scripts:Edit`
  - `User:Memberships:Read`
  - `User:User Details:Read`
- Upstream registry url, username and password. In the case of Docker Hub (url would be `index.docker.io`) - username and a PAT (personal access token) with `Read & Write` permissions. 
- [`pnpm`](https://pnpm.io/installation)
- [`wrangler`](https://developers.cloudflare.com/workers/wrangler/install-and-update/)

## Setup

1. Clone the repository 
2. Fill in the values at the top of the `cf-registry-automation.sh` / provide values via command line arguments. Refer to `cf-registry-automation.sh --help` for more information
3. Run the script
4. Authenticate with your newly configured registry and try pulling some base image from upstream registry, for example: `docker pull <your-registry-url>/node:20`, which should automatically resolve to `docker pull <upstream-registry-url>/node:20` and pull the image from upstream registry through your Cloudflare registry, and cache it in R2 for future use.