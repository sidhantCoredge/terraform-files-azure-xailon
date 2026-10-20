# terraform-files-azure-xailon

This repo contains all the terraform files.



*** BASTION Commands for az login/ kubelogin and making the rbacs work***

 # 1. kubelogin, system-wide
  sudo install -o root -g root -m 0755 /home/azureuser/bin/kubelogin /usr/local/bin/kubelogin

  # 2. azure-cli, system-wide from Microsoft's apt repo
  sudo mkdir -p /etc/apt/keyrings
  curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
    | sudo gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
  sudo chmod 644 /etc/apt/keyrings/microsoft.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ jammy main" \
    | sudo tee /etc/apt/sources.list.d/azure-cli.list
  sudo apt-get update && sudo apt-get install -y azure-cli

  # 3. remove the old pip shim, which shadows the real one on PATH
  sudo mv /usr/local/bin/az /usr/local/bin/az.pip-shim.disabled
  hash -r
  which az          # should now be /usr/bin/az
  az version

  Step 3 matters: /usr/local/bin comes before /usr/bin on PATH, so without it az keeps resolving to the broken shim.

  Then get your kubeconfig — still in your own session:

  az login --use-device-code
  az aks get-credentials -g rg-tokenfactory -n aks-tokenfactory --overwrite-existing
  kubelogin convert-kubeconfig -l azurecli
  kubectl auth whoami
  kubectl get nodes
