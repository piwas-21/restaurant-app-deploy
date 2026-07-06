# Tenant site block — rendered by provision-tenant.sh into
# /opt/rumi/deploy/caddy-tenants/<slug>.caddy (box-only, never committed).
# Imported by Caddyfile.staging's `import /etc/caddy/tenants/*.caddy`.
# Routing mirrors the main site (uploads / api+SSE / app) minus the ops routes
# (/dev-portal, /logs) — those stay on the box's primary site only.
__DOMAIN__ {
	encode zstd gzip

	# Tenant uploads — served off the tenant's bind-mounted uploads dir via the
	# shared Caddy's read-only /srv/tenants parent mount.
	handle_path /uploads/* {
		root * /srv/tenants/__SLUG__/uploads
		file_server
	}

	# Frontend's version-aggregation route — must win over /api/* (Caddy matches
	# by path specificity, so this is safe regardless of order).
	handle /api/frontend/version {
		reverse_proxy frontend-__SLUG__:3000
	}

	# API + SSE order-event stream. flush_interval -1 disables buffering so SSE
	# reaches the cashier/kitchen UIs immediately.
	handle /api/* {
		reverse_proxy backend-__SLUG__:8080 {
			flush_interval -1
		}
	}

	# Next.js app
	handle {
		reverse_proxy frontend-__SLUG__:3000
	}
}
