FROM alpine:3.22
# working as of 2025-06-03 on Alpine version 3.22.0
# not working on Alpine version 3.21.3

ARG BUILD_DATE

# first, a bit about this container
LABEL org.opencontainers.image.created="${BUILD_DATE}" 

# Update apk repositories and install gpsd
RUN apk update && \
    apk add --no-cache \
    pps-tools \
    gpsd \
    gpsd-clients \
    chrony \
    bash \
    sudo \ 
    nano \ 
    && rm -rf /var/cache/apk/*

# Expose the gpsd port (2947 is the default gpsd port)
EXPOSE 2947

# Expose the chrony ntp port
EXPOSE 123/udp

# marking volumes that need to be writable
VOLUME /etc/chrony /run/chrony /var/lib/chrony /var/log/chrony

# let docker know how to test container health
HEALTHCHECK CMD chronyc -n tracking || exit 1

# Add entrypoint script (as before)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set the entrypoint script
ENTRYPOINT ["/entrypoint.sh"]
