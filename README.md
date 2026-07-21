<h4 align="center">
  Grow wallet adapters for Alchemy Modular Account v2.
</h4>

<p align="center">
  <a href="https://github.com/getgrowapp/smart-contracts/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/getgrowapp/smart-contracts/ci.yml?style=flat&amp;labelColor=1C2C2E&amp;label=ci&amp;color=BEC5C9&amp;logo=GitHub%20Actions&amp;logoColor=BEC5C9" alt="CI"></a>
  <a href="https://deepwiki.com/getgrowapp/smart-contracts"><img src="https://deepwiki.com/badge.svg" alt="Ask DeepWiki"></a>
</p>

<p align="center">
  <a href="docs/ARCHITECTURE.md">Architecture</a> •
  <a href="SECURITY.md">Security</a> 
</p>

## Overview

GrowYield lets smart-account owners authorize account-scoped policy owners to execute bounded, sponsor-paid yield operations through pinned adapters.

## Architecture

See the [architecture documentation](docs/ARCHITECTURE.md) for the contract catalogue, security model, deployment guidance, and integration flows.

## Development

```bash
git submodule update --init
forge build
forge test
```

## Security

See the [security policy](SECURITY.md) for security documentation and reporting guidance.
