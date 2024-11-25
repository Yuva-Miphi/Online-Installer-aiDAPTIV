#!/bin/bash

# Variable to store the chosen user
deploy_usr=""

# To cleanup installation cache
cleanup() 
{
    # Purge packages in problematic states
    sudo dpkg -l | grep -E '^rc|^iU|^iF|^hF' | awk '{print $2}' | xargs -r sudo dpkg --purge >/dev/null 2>&1
    sudo dpkg -l | grep -E '^(rc|iU|iF|hF)' | awk '{print $2}' | xargs -r sudo dpkg --remove --force-remove-reinstreq >/dev/null 2>&1
    # Cleaning up from /var/cache/apt/archives
    sudo apt-get clean
    # Handle pip cleanup if pip is installed
    if command -v pip &>/dev/null 2>&1; then
        pip cache purge &>/dev/null 2>&1
    fi
    echo "Exiting....."
}


#Trap EXIT signals
trap cleanup EXIT


remove_nvidia_driver() {
    # Check if NVIDIA kernel modules are loaded
    if lsmod | grep -q "nvidia"; then
        echo "NVIDIA driver is present but has an incompatible version. Proceeding to remove it..."
        # Remove NVIDIA driver and utils
        sudo apt-get purge --auto-remove -y nvidia-*
        # Stop and disable the NVIDIA persistence daemon if running
        sudo systemctl stop nvidia-persistenced
        sudo systemctl disable nvidia-persistenced
        # Clean up residual files
        sudo apt-get autoremove -y
        sudo apt-get clean
        echo "NVIDIA driver and utilities have been removed."
    fi
}


remove_cuda() {
    # Check if CUDA is installed
    if dpkg -l | grep -q "cuda"; then
        echo "Cuda Toolkit is present but has an incompatible version. Proceeding to remove it..."
        # Remove CUDA and all related packages
        sudo apt-get purge --auto-remove -y cuda-keyring
        sudo apt-get purge --auto-remove -y cuda*   
        # Remove NVIDIA package repositories (if any)
        sudo rm -f /etc/apt/sources.list.d/cuda*
        sudo rm -f /etc/apt/sources.list.d/nvidia*
        # Remove CUDA specific directories
        sudo rm -rf /usr/local/cuda*
        # Remove keyring if present, ignoring errors
        sudo rm -f /usr/share/keyrings/cuda-archive-keyring.gpg || true
        # Clean up any residual packages and cache
        sudo apt-get autoremove -y
        sudo apt-get clean
        echo "CUDA has been removed completely."
    fi
}


#Check the installed packages are required one.
check_packages() {
    #check nvidia-driver-535
    if ! sudo dpkg -l | grep -q "^ii  nvidia-driver-535"; then
        remove_nvidia_driver
    fi

    #check cuda-toolkit-12-3
    if ! sudo dpkg -l | grep -q "^ii  cuda-toolkit-12-3"; then
        remove_cuda
    fi
}


# Function to check available space on mount point "/"
check_space() {
    local required_space=$1
    # Convert required space to bytes for comparison
    required_bytes=$(numfmt --from=iec $required_space)
    # Retrieve available space in bytes (from df -h output)
    available_space=$(df -h / | awk 'NR==2 {print $4}')
    available_bytes=$(df --block-size=1 / | awk 'NR==2 {print $4}')

    if [[ $available_bytes -ge $required_bytes ]]; then
        echo "✔ Sufficient space available. Required: $required_space, Available: $available_space"
    else
        echo "✘ Insufficient space. Required: $required_space, Available: $available_space"
        exit 1
    fi
}



#verify root user
#else exit
check_root() {
    if [ "$UID" -ne 0 ]; then
	trap - EXIT 
        echo "✘ Error: You must be a root user!"
        exit 1 
    fi
}


# Function to select the installation user
select_install_user() {
    echo "******Deploy aiDAPTIV Middleware*****"
    echo "1) Deploy at Root"
    echo "2) Deploy at User"
    echo "3) Exit"
    read -p "Enter choice [1, 2, or 3]: " choice

    case "$choice" in
        1)
            deploy_usr=$(whoami) #root user
            ;;
        2)  
            deploy_usr=${SUDO_USER:-$USER} # To fetch sudo user's name
            ;;
        3)
            echo "Exiting...."
            trap - EXIT
            exit 0
            ;;
        *)
            echo "✘ Invalid choice. Please select a valid option."
            ;;
    esac

    export deploy_usr
}


# Reload NVIDIA modules to avoid rebooting the system
reload_nvidia_modules() {
    local modules=("nvidia" "nvidia-uvm" "nvidia-modeset" "nvidia-drm")

    for mod in "${modules[@]}"; do
        if ! sudo modprobe "$mod"; then
            echo "✘ Error: Failed to load NVIDIA module $mod."
            exit 1
        else
            echo "✔ NVIDIA module $mod loaded successfully."
        fi
    done
}


#Function to install nvidia drivers and cuda
install_drivers_and_cuda() {
    #Check and remove if packages with incompatible version are installed
    check_packages

    echo "Starting installation of Nvidia drivers and CUDA toolkit..."

    if ! sudo apt update; then
        echo "✘ Error: Failed to update package list. Please check your internet connection or package sources."
        exit 1
    fi

    # Install Nvidia drivers
    echo "Installing Nvidia drivers (nvidia-driver-535 and nvidia-utils-535)..."
    if ! sudo apt install -y nvidia-driver-535 nvidia-utils-535; then
        echo "✘ Error: Failed to install Nvidia drivers. Please ensure your system is compatible."
        exit 1
    fi

    echo "Reloading Nvidia modules..."
    #reload_nvidia_modules

    # Install CUDA toolkit
    echo "Installing CUDA toolkit (version 12.3)..."
    CUDA_KEYRING="cuda-keyring_1.1-1_all.deb"
    CUDA_REPO_URL="https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/$CUDA_KEYRING"

    #Fetch the key from nvidia cloud
    if ! wget -q "$CUDA_REPO_URL" -O "$CUDA_KEYRING"; then
        echo "✘ Error: Failed to download CUDA keyring from $CUDA_REPO_URL."
        exit 1
    fi

    #Execute tke key deb
    if ! sudo dpkg -i "$CUDA_KEYRING"; then
        echo "✘ Error: Failed to install CUDA keyring."
        exit 1
    fi
    
    #Update the apt package manage to get access to cuda package
    if ! sudo apt-get update; then
        echo "✘ Error: Failed to update package list after adding CUDA repository."
        exit 1
    fi

    #install cuda-toolkit
    if ! sudo apt-get install -y cuda-toolkit-12-3; then
        echo "✘ Error: Failed to install CUDA toolkit. Please ensure compatibility with your system."
        exit 1
    fi

    #Add cuda to env path. 
    echo "Adding CUDA to environment..."
    echo 'export PATH="/usr/local/cuda/bin${PATH:+:${PATH}}"' >> ~/.bashrc
    source ~/.bashrc

    echo "✔ Nvidia drivers and CUDA toolkit installation completed successfully."
}


#Function to install pip and other required apt packages
install_other_apt_packages() {
    echo "Starting installation of pip and other required apt packages..."

    if ! sudo apt update; then
        echo "✘ Error: Failed to update package list. Please check your internet connection or package sources."
        exit 1
    fi

    #Installing all other required apt packages
    REQUIRED_PACKAGES="wget libaio1 libaio-dev liburing2 liburing-dev libboost-all-dev python3-pip libstdc++-12-dev gcc-12 g++-12 vim mdadm lvm2"
    if ! sudo apt install -y $REQUIRED_PACKAGES; then
        echo "✘ Error: Failed to install required packages. Please check your package sources or resolve conflicts."
        exit 1
    fi

    if ! sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-12 50; then
        echo "✘ Error: Failed to configure g++-12 as the default alternative. Check if g++-12 is correctly installed."
        exit 1
    fi

    #verifying whether the pip is installed correctly.
    echo "Verifying pip installation..."
    if ! python3 -m pip --version; then
        echo "✘ Error: Pip installation failed. Please check your Python3 and pip configuration."
        exit 1
    fi
    echo "✔ Installation of pip and other required apt packages completed successfully."
}


#Function to check python3 is available or not
check_python3()
{
    PYTHON_PATH=$(which python3 | xargs dirname)
    echo "Found python3 at:"$PYTHON_PATH

    if [ "$PYTHON_PATH" == "" ]; then
        echo "✘ Python3 Path is not found. Please check 'which python3' working correctly."
        exit 1
    fi
}


setup_aidaptiv_package()
{
    #Prepare directory path to deploy
    mkdir -p /home/$deploy_usr/
    mkdir -p /home/$deploy_usr/Desktop/
    
    # Delete old aiDAPTIV+
    rm -rf /home/$deploy_usr/Desktop/dm /home/$deploy_usr/Desktop/aiDAPTIV2
    mkdir /home/$deploy_usr/Desktop/dm /home/$deploy_usr/Desktop/aiDAPTIV2

    # Download aiDAPTIV+ Package
    TAR_NAME="vNXUN_2_01_00.tar"
    rm -f $TAR_NAME
    if ! wget --tries=3 https://phisonbucket.s3.ap-northeast-1.amazonaws.com/$TAR_NAME --no-check-certificate; then
        read -p "✘ Can't get $TAR_NAME from cloud, Please enter the path to the $TAR_NAME file: " filepath
        tar xvf "$filepath" -C /home/$deploy_usr/Desktop/aiDAPTIV2
        echo 'unzip package'
    else
        echo 'Get package from cloud'
        tar xvf $TAR_NAME -C /home/$deploy_usr/Desktop/aiDAPTIV2
        echo 'unzip package'
    fi
}


# Append env paths
appenvpath () {
    case ":$PATH:" in
        *:"$1":*)
            echo "ENV path already exists in the PATH"
            ;;
        *)
            # Check if the PATH line already exists in the .bashrc file
            grep -qxF "export PATH=\"/home/$USER/.local/bin:\$PATH\"" "/home/$deploy_usr/.bashrc" || \
            echo "export PATH=\"/home/$USER/.local/bin:\$PATH\"" >> "/home/$deploy_usr/.bashrc"
    esac

    # Source the user's .bashrc
    sudo -u $deploy_usr bash -c "source /home/$deploy_usr/.bashrc"
}



#Function to install required python packages
install_python_packages()
{
    PYTHON_PATH=$(which python3 | xargs dirname)

    #Get the required pip packages list from requirements.txt
    REQUIREMENTS_FILE="/home/$deploy_usr/Desktop/aiDAPTIV2/requirements.txt"

    # Validate requirements file
    if [[ ! -f $REQUIREMENTS_FILE ]]; then
        echo "✘ Error: requirements.txt file not found at $REQUIREMENTS_FILE."
        exit 1
    fi

    # Perform installation based on the value of $deploy_usr
    if [[ "$deploy_usr" != "root" ]]; then
        echo "Installing required packages for user $deploy_usr..."
        echo "Packages will be installed in $(sudo -u $deploy_usr python3 -m site --user-site)"
        
        #Installing python packages at user level.
        #Overriding any existing installed python packages
        sudo -u $deploy_usr pip install --user --force-reinstall -r "$REQUIREMENTS_FILE" || {
            echo "✘ Error: Failed to install required packages for user '$deploy_usr'."
            exit 1
        }      
        # Add to the user's PATH
        appenvpath /home/$deploy_usr/.local/bin       
        echo "✔ Successfully installed packages for user '$deploy_usr'."

    else
        # System-wide installation for "root"
        echo "Installing required packages for user 'root'..."
        INSTALL_PATH=$(realpath "$PYTHON_PATH/../lib/python3.10/site-packages/")
        echo "Packages will be installed in $INSTALL_PATH"
        
        #Overriding any existing installed python packages
        pip install --force-reinstall -r "$REQUIREMENTS_FILE" || {
            echo "✘ Error: Failed to install required packages for user 'root'."
            exit 1
        }
        
        echo "✔ Successfully installed packages for user 'root'."
    fi

}


#Function to check phisonai2 is available..
check_phisonai2() 
{
    echo -e "Validating phisonai2....."
    is_available=0

    # Check version for root
    root_version=$(phisonai2 -v 2>/dev/null)
    if [ $? -eq 0 ]; then
        echo "✔ phisonai2 is available for root."
        echo "phisonai2 version: $root_version"
        is_available=1
        return
    fi

    # Check version for specified user
    user_version=$(su - $deploy_usr -c 'phisonai2 -v 2>/dev/null')
    if [ $? -eq 0 ]; then
        echo "✔ phisonai2 is available for user: $deploy_usr."
        echo "phisonai2 version: $user_version"
        is_available=1
        return
    fi

    # Final check
    if [ $is_available -eq 0 ]; then
        echo "✘ Error: phisonai2 is not available or functional for root or user: $deploy_usr."
        echo "Please ensure it is installed, functional, and added to the PATH."
        exit 1
    fi
}


#Function to deploy aiDAPTIV+ on bare metal
deploy_aiDAPTIV()
{
    #check the script is running at root 
    check_root

    #check sufficient space is available
    check_space 22G

    #Select user for deployment
    select_install_user

    #Installing nvidia-drivers and cuda-toolkit
    install_drivers_and_cuda

    #Installing other packages like pip and liburing2 etc.,
    install_other_apt_packages

    #Check python3 is available
    check_python3

    #Fetch and extract aiDAPTIV2 tar file
    setup_aidaptiv_package

    #Installing required python packages
    install_python_packages

 
    cd /home/$deploy_usr/Desktop/aiDAPTIV2

    # Set executable permissions
    sudo chmod +x bin/*
    echo 'Edited bin permissions'
    mv *.so ./phisonlib
    sudo chmod +x ./phisonlib/ada.exe
    sudo setcap cap_sys_admin,cap_dac_override=+eip ./phisonlib/ada.exe


    PYTHON_PATH=$(which python3 | xargs dirname)

    echo "Setting up phisonai2....."
    if [[ "$PYTHON_PATH" == "/usr/bin" && "$deploy_usr" != "root" ]]; then
        # Move bin files to dm directory
        cp bin/* /home/$deploy_usr/Desktop/dm/
        mv bin/* /home/$deploy_usr/.local/bin/
        rm -rf bin

        rm -rf /home/$deploy_usr/.local/lib/python3.10/site-packages/phisonlib
        mv phisonlib /home/$deploy_usr/.local/lib/python3.10/site-packages/
        rm -rf phisonlib
        # echo 'export PYTHONPATH="/home/$USER/.local/lib/python3.10/site-packages/phisonlib"' >> ~/.bashrc

    else
        # Move bin files to dm directory
        cp bin/* /home/$deploy_usr/Desktop/dm/
        mv bin/* $PYTHON_PATH
        rm -rf bin

        if [ "$deploy_usr" == "root" ] ; then
            rm -rf /usr/local/lib/python3.10/dist-packages/phisonlib
            mv phisonlib /usr/local/lib/python3.10/dist-packages
            rm -rf phisonlib
            # echo 'export PYTHONPATH="/usr/local/lib/python3.10/dist-packages/phisonlib"' >> ~/.bashrc

        else
            rm -rf  $PYTHON_PATH/../lib/python3.10/site-packages/phisonlib
            mv phisonlib $PYTHON_PATH/../lib/python3.10/site-packages/
            rm -rf phisonlib
            # echo 'export PYTHONPATH="$PYTHON_PATH/../lib/python3.10/site-packages/phisonlib"' >> ~/.bashrc
        fi

    fi

    # echo 'export PYTHONPATH="/home/$USER/.local/lib/python3.10/site-packages/Phisonlib"' >> ~/.bashrc
    # echo 'export PYTHONPATH="/home/$USER/Desktop/aiDAPTIV2:$PYTHONPATH"' >> ~/.bashrc

    source ~/.bashrc
    sudo -u $deploy_usr bash -c "source /home/$deploy_usr/.bashrc"
    
    check_phisonai2

    echo '✔ Deploy Phison aiDAPTIV+ successfully..'
}

deploy_aiDAPTIV