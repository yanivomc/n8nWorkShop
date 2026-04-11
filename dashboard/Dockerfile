FROM nginx:alpine

# Copy dashboard HTML
COPY index.html /usr/share/nginx/html/index.html

# Startup script — injects env vars as config.js before nginx starts
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 80

CMD ["/docker-entrypoint.sh"]
