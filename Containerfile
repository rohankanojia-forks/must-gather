ARG OPENSHIFT_VERSION=4.21

# Base this image on the standard OpenShift must-gather image
FROM quay.io/openshift/origin-must-gather:${OPENSHIFT_VERSION}

# Add the must-gather script to the image
COPY --chmod=755 gather_eclipse_che.sh /usr/bin/gather

# Set the default command for the image
CMD ["bash", "/usr/bin/gather"]
