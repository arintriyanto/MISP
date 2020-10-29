#!/bin/bash

# Main Install on RHEL function
installMISPRHEL () {

    debug "Installing System Dependencies"
    yumInstallCoreDeps

    debug "Enabling Haveged for additional entropy"
    sudo yum install haveged -y
    sudo systemctl enable --now haveged.service

    debug "Installing MISP code"
    installCoreRHEL
    
    debug "Install Cake PHP"
    installCake_RHEL
    
    echo "Core Intallation finished, check on port 443 to see the Web UI"
  fi
}
# End installMISPRHEL ()

yumInstallCoreDeps () {
  # Install the dependencies:
  sudo yum install gcc git zip rh-git218 \
                   httpd24 \
                   mod_ssl \
                   rh-redis32 \
                   rh-mariadb102 \
                   libxslt-devel zlib-devel ssdeep-devel -y

  # Enable and start redis
  sudo systemctl enable --now rh-redis32-redis.service

  WWW_USER="apache"
  SUDO_WWW="sudo -H -u $WWW_USER"
  RUN_PHP="/usr/bin/scl enable rh-php72"
  PHP_INI="/etc/opt/rh/rh-php72/php.ini"
  # Install PHP 7.2 from SCL, see https://www.softwarecollections.org/en/scls/rhscl/rh-php72/
  sudo yum install rh-php72 rh-php72-php-fpm rh-php72-php-devel \
                   rh-php72-php-mysqlnd \
                   rh-php72-php-mbstring \
                   rh-php72-php-xml \
                   rh-php72-php-bcmath \
                   rh-php72-php-opcache \
                   rh-php72-php-gd -y

  # Python 3.6 is now available in RHEL 7.7 base
  sudo yum install python3 python3-devel -y

  sudo systemctl enable --now rh-php72-php-fpm.service
}

# <snippet-begin 1_mispCoreInstall_RHEL.sh>
installCoreRHEL () {
  # Download MISP using git in the /var/www/ directory.
  sudo mkdir $PATH_TO_MISP
  sudo chown $WWW_USER:$WWW_USER $PATH_TO_MISP
  cd /var/www
  $SUDO_WWW git clone https://github.com/MISP/MISP.git
  cd $PATH_TO_MISP
  ##$SUDO_WWW git checkout tags/$(git describe --tags `git rev-list --tags --max-count=1`)
  # if the last shortcut doesn't work, specify the latest version manually
  # example: git checkout tags/v2.4.XY
  # the message regarding a "detached HEAD state" is expected behaviour
  # (you only have to create a new branch, if you want to change stuff and do a pull request for example)

  # Fetch submodules
  $SUDO_WWW git submodule update --init --recursive
  # Make git ignore filesystem permission differences for submodules
  $SUDO_WWW git submodule foreach --recursive git config core.filemode false
  # Make git ignore filesystem permission differences
  $SUDO_WWW git config core.filemode false

  # Install packaged pears
  sudo $RUN_PHP -- pear channel-update pear.php.net
  sudo $RUN_PHP -- pear install ${PATH_TO_MISP}/INSTALL/dependencies/Console_CommandLine/package.xml
  sudo $RUN_PHP -- pear install ${PATH_TO_MISP}/INSTALL/dependencies/Crypt_GPG/package.xml

  # Create a python3 virtualenv
  $SUDO_WWW $RUN_PYTHON -- virtualenv -p python3 $PATH_TO_MISP/venv
  sudo mkdir /usr/share/httpd/.cache
  sudo chown $WWW_USER:$WWW_USER /usr/share/httpd/.cache
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U pip setuptools

  cd $PATH_TO_MISP/app/files/scripts
  $SUDO_WWW git clone https://github.com/CybOXProject/python-cybox.git
  $SUDO_WWW git clone https://github.com/STIXProject/python-stix.git
  $SUDO_WWW git clone --branch master --single-branch https://github.com/lief-project/LIEF.git lief
  $SUDO_WWW git clone https://github.com/CybOXProject/mixbox.git

  cd $PATH_TO_MISP/app/files/scripts/python-cybox
  # If you umask is has been changed from the default, it is a good idea to reset it to 0022 before installing python modules
  UMASK=$(umask)
  umask 0022
  cd $PATH_TO_MISP/app/files/scripts/python-stix
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install .

  # install mixbox to accommodate the new STIX dependencies:
  cd $PATH_TO_MISP/app/files/scripts/mixbox
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install .

  # install STIX2.0 library to support STIX 2.0 export:
  cd $PATH_TO_MISP/cti-python-stix2
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install .

  # install maec
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U maec

  # install zmq
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U zmq

  # install redis
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U redis

  # lief needs manual compilation
  sudo yum install devtoolset-7 cmake3 cppcheck -y

  # FIXME: This does not work!
  cd $PATH_TO_MISP/app/files/scripts/lief
  $SUDO_WWW mkdir build
  cd build
  $SUDO_WWW scl enable devtoolset-7 rh-python36 "bash -c 'cmake3 \
  -DLIEF_PYTHON_API=on \
  -DPYTHON_VERSION=3.6 \
  -DPYTHON_EXECUTABLE=$PATH_TO_MISP/venv/bin/python \
  -DLIEF_DOC=off \
  -DCMAKE_BUILD_TYPE=Release \
  ..'"
  $SUDO_WWW make -j3 pyLIEF

  if [ $? == 2 ]; then
    # In case you get "internal compiler error: Killed (program cc1plus)"
    # You ran out of memory.
    # Create some swap
    sudo dd if=/dev/zero of=/var/swap.img bs=1024k count=4000
    sudo mkswap /var/swap.img
    sudo swapon /var/swap.img
    # And compile again
    $SUDO_WWW make -j3 pyLIEF
    sudo swapoff /var/swap.img
    sudo rm /var/swap.img
  fi

  # The following adds a PYTHONPATH to where the pyLIEF module has been compiled
  echo /var/www/MISP/app/files/scripts/lief/build/api/python |$SUDO_WWW tee /var/www/MISP/venv/lib/python3.6/site-packages/lief.pth

  # install magic, pydeep
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U python-magic git+https://github.com/kbandla/pydeep.git plyara

  # install PyMISP
  cd $PATH_TO_MISP/PyMISP
  $SUDO_WWW $PATH_TO_MISP/venv/bin/pip install -U .

  # Enable python3 for php-fpm
  echo 'source scl_source enable rh-python36' | sudo tee -a /etc/opt/rh/rh-php72/sysconfig/php-fpm
  sudo sed -i.org -e 's/^;\(clear_env = no\)/\1/' /etc/opt/rh/rh-php72/php-fpm.d/www.conf
  sudo systemctl restart rh-php72-php-fpm.service

  umask $UMASK

  # Enable dependencies detection in the diagnostics page
  # This allows MISP to detect GnuPG, the Python modules' versions and to read the PHP settings.
  # The LD_LIBRARY_PATH setting is needed for rh-git218 to work, one might think to install httpd24 and not just httpd ...
  echo "env[PATH] = /opt/rh/rh-git218/root/usr/bin:/opt/rh/rh-redis32/root/usr/bin:/opt/rh/rh-python36/root/usr/bin:/opt/rh/rh-php72/root/usr/bin:/usr/local/bin:/usr/bin:/bin" |sudo tee -a /etc/opt/rh/rh-php72/php-fpm.d/www.conf
  echo "env[LD_LIBRARY_PATH] = /opt/rh/httpd24/root/usr/lib64/" |sudo tee -a /etc/opt/rh/rh-php72/php-fpm.d/www.conf
  sudo systemctl restart rh-php72-php-fpm.service
}
# <snippet-end 1_mispCoreInstall_RHEL.sh>


installCake_RHEL ()
{
  sudo chown -R $WWW_USER:$WWW_USER $PATH_TO_MISP
  sudo mkdir /usr/share/httpd/.composer
  sudo chown $WWW_USER:$WWW_USER /usr/share/httpd/.composer
  cd $PATH_TO_MISP/app
  # Update composer.phar (optional)
  #$SUDO_WWW $RUN_PHP -- php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
  #$SUDO_WWW $RUN_PHP -- php -r "if (hash_file('SHA384', 'composer-setup.php') === '48e3236262b34d30969dca3c37281b3b4bbe3221bda826ac6a9a62d6444cdb0dcd0615698a5cbe587c3f0fe57a54d8f5') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;"
  #$SUDO_WWW $RUN_PHP "php composer-setup.php"
  #$SUDO_WWW $RUN_PHP -- php -r "unlink('composer-setup.php');"
  $SUDO_WWW $RUN_PHP "php composer.phar require kamisama/cake-resque:4.1.2"
  $SUDO_WWW $RUN_PHP "php composer.phar config vendor-dir Vendor"
  $SUDO_WWW $RUN_PHP "php composer.phar install"

  ## sudo yum install php-redis -y
  sudo scl enable rh-php72 'pecl channel-update pecl.php.net'
  sudo scl enable rh-php72 'yes no|pecl install redis'
  echo "extension=redis.so" |sudo tee /etc/opt/rh/rh-php72/php-fpm.d/redis.ini
  sudo ln -s /etc/opt/rh/rh-php72/php-fpm.d/redis.ini /etc/opt/rh/rh-php72/php.d/99-redis.ini
  
  sudo ln -s /usr/lib64/libfuzzy.so /usr/lib/libfuzzy.so
  sudo scl enable rh-php72 'pecl install ssdeep'
  echo "extension=ssdeep.so" |sudo tee /etc/opt/rh/rh-php72/php.d/99-ssdeep.ini

  # Install gnupg extension
  sudo yum install gpgme-devel -y
  sudo scl enable rh-php72 'pecl install gnupg'
  echo "extension=gnupg.so" |sudo tee /etc/opt/rh/rh-php72/php-fpm.d/gnupg.ini
  sudo ln -s /etc/opt/rh/rh-php72/php-fpm.d/gnupg.ini /etc/opt/rh/rh-php72/php.d/99-gnupg.ini
  sudo systemctl restart rh-php72-php-fpm.service

  # If you have not yet set a timezone in php.ini
  echo 'date.timezone = "Asia/Jakarta"' |sudo tee /etc/opt/rh/rh-php72/php-fpm.d/timezone.ini
  sudo ln -s ../php-fpm.d/timezone.ini /etc/opt/rh/rh-php72/php.d/99-timezone.ini


  # Recommended: Change some PHP settings in /etc/opt/rh/rh-php72/php.ini
  # max_execution_time = 300
  # memory_limit = 512M
  # upload_max_filesize = 50M
  # post_max_size = 50M
  for key in upload_max_filesize post_max_size max_execution_time max_input_time memory_limit
  do
      sudo sed -i "s/^\($key\).*/\1 = $(eval echo \${$key})/" $PHP_INI
  done
  sudo systemctl restart rh-php72-php-fpm.service

  # To use the scheduler worker for scheduled tasks, do the following:
  sudo cp -fa $PATH_TO_MISP/INSTALL/setup/config.php $PATH_TO_MISP/app/Plugin/CakeResque/Config/config.php
}
# <snippet-begin 1_installCake_RHEL.sh>



# If RHEL/CentOS is detected, run appropriate script
if [[ "${FLAVOUR}" == "rhel" ]] || [[ "${FLAVOUR}" == "centos" ]]; then
  installMISPRHEL
  echo "Installation done !"
  exit
fi
