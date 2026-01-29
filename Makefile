kind-install:
	# For AMD64 / x86_64
	[ $(uname -m) = x86_64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
	# For ARM64
	[ $(uname -m) = aarch64 ] && curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-arm64
	chmod +x ./kind
	sudo mv ./kind /usr/local/bin/kind

	kind create cluster

zsh-install:
	sudo apt install zsh -y
	sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" -y
	git clone https://github.com/romkatv/powerlevel10k.git $ZSH_CUSTOM/themes/powerlevel10k
	git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
	git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
	git clone https://github.com/agkozak/zsh-z $ZSH_CUSTOM/plugins/zsh-z

prometheus-install:
	helm -n test1 install prometheus oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack

golang-install:
	sudo apt-get update
	wget https://go.dev/dl/go1.25.5.linux-amd64.tar.gz
	sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go1.25.5.linux-amd64.tar.gz
	echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.zshrc
	source ~/.zshrc