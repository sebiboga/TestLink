FROM supersqa/testlink:1.9.20

RUN sed -i 's|deb.debian.org|archive.debian.org|g' /etc/apt/sources.list && \
    sed -i 's|security.debian.org|archive.debian.org|g' /etc/apt/sources.list && \
    sed -i '/buster-updates/d' /etc/apt/sources.list && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends libgd-dev autoconf && \
    cd /usr/src/php-*/ext/gd && phpize && \
    ./configure --with-freetype-dir=/usr --with-jpeg-dir=/usr --with-png-dir=/usr && \
    make -j2 && make install && \
    echo 'extension=gd.so' > /usr/local/etc/php/conf.d/gd.ini && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
