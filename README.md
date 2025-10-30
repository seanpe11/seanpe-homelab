# Sean Pe's Homelab

This is a collection of my personal homelab setup, with the explicit goal of documentation and holding the configurations for my k3s cluster and hosting services, and the implicit goal of getting good at DevOps.

This is inspired heavily by [Mischa van den Burg's homelab](https://github.com/Mischavandenburg/homelab) and also serves as my playground in preparation for getting my CKA cert.

## Hardware
- HP Probook as control pane
- Raspberry Pi 4 as worker node (to add)
- Intel NUC as worker node (to add)
- MacBook Pro as worker node (might add)
- Personal laptop as worker node (tainted/tolerated for gpu tasks like llms, high-compute, etc)

## Infrastructure
- Kubernetes cluster (k3s)
- cloudflared tunnels + zero trust networking for DNS 
- Flux CD + n8n for GitOps navigation

# ToDo 
- [x] Add k3s cluster
- [ ] Add cloudflared tunnels
- [ ] Add Flux CD
  - [ ] Add Gitea
  - [ ] Deploy www.seanpe.io
  - [ ] Deploy notes.seanpe.io
