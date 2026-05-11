# Backlogs

# GitHub
https://github.com/arthurking87?tab=repositories

# zsh
https://www.kwchang0831.dev/dev-env/ubuntu/oh-my-zsh

vi ~/.zshrc
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-z)

# kind 
https://kind.sigs.k8s.io/

# Build
docker build -t t-operator:0.24.0 .
kind load docker-image t-operator:0.24.0

# Mariadb
mariadb -u root -p${MARIADB_ROOT_PASSWORD}

STOP ALL SLAVES; FLUSH PRIVILEGES; START ALL SLAVES;

show all slaves status\G