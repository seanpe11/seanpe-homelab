# Networking

## DNS

### cloudflared

[cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation/) is a tool for creating secure tunnels to any TCP or UDP service. Most services within this homelab will be exposed via cloudflared tunnels, since it's really easy to setup a new service + dns with it. Additionally, it magics away the science of secure protocols (https) and saves me the hassle of setting up an SSL certificate for most of the services I need.

### nginx + any other additional networking setups

I still use nginx just for the sake of practice, and will note in the future which services will use nginx for networking. Cloudflared doesn't do great with UDP, so there is a strong usecase for nginx + other ways to traffic within this cluster.

## VPN

I got a pretty good deal with surfshark, so I just use that for now via OpenVPN. Reference for setup [here](https://support.surfshark.com/hc/en-us/articles/360011051133-How-to-set-up-manual-OpenVPN-connection-using-Linux-Terminal). This isn't essential for the cluster to operate, given that cloudflared tunnels abstract a lot of the DNS process, but it's a nice to have. OpenVPN is setup directly on the machine as opposed to operating within the cluster.
