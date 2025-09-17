FROM nginx:alpine
COPY app/ /usr/share/nginx/html/
# опционально:
# COPY docker/nginx.conf /etc/nginx/conf.d/default.conf