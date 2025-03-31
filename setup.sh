#!/bin/bash
#
# node-init.sh - Automated node initialization script
#

set -e
SCRIPT_VERSION="1.0.0"

# CONFIGURATION AND SETUP
# GitHub credentials - These will be provided as environment variables when executing the script

# SSH key configuration
SSH_KEY_PATH="$HOME/.ssh/github_key"
FORCE_OVERWRITE="false"

# Additional settings
RUN_ADDITIONAL_TASKS="true"

# Log file setup
LOG_DIR="/var/log/node-init"
LOG_FILE="$LOG_DIR/node-init.log"
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to log messages
log() {
  local level=$1
  local message=$2
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() {
  log "INFO" "${BLUE}$1${NC}"
}

log_success() {
  log "SUCCESS" "${GREEN}$1${NC}"
}

log_warning() {
  log "WARNING" "${YELLOW}$1${NC}"
}

log_error() {
  log "ERROR" "${RED}$1${NC}"
}

# Display script header
display_header() {
  echo -e "\n${GREEN}=======================================${NC}"
  echo -e "${GREEN} Node Initialization Script v${SCRIPT_VERSION}${NC}"
  echo -e "${GREEN}=======================================${NC}\n"
  log_info "Starting node initialization"
}

# Validate required configuration
validate_config() {
  log_info "Validating configuration"
  
  # Validate required configuration
  if [ -z "$GITHUB_USERNAME" ] || [ -z "$GITHUB_EMAIL" ] || [ -z "$GITHUB_TOKEN" ]; then
    log_error "Missing required configuration. Please set GITHUB_USERNAME, GITHUB_EMAIL, and GITHUB_TOKEN"
    exit 1
  fi
  
  log_success "Configuration validated successfully"
}

# Check for required dependencies
check_dependencies() {
  log_info "Checking dependencies"
  
  MISSING_DEPS=false
  for cmd in ssh-keygen curl grep cut; do
    if ! command -v $cmd &> /dev/null; then
      log_error "Missing dependency: $cmd"
      MISSING_DEPS=true
    fi
  done
  
  if [ "$MISSING_DEPS" = true ]; then
    log_error "Please install missing dependencies and try again"
    exit 1
  fi
  
  log_success "All dependencies are installed"
}

# Generate SSH key if it doesn't exist
generate_ssh_key() {
  log_info "Setting up SSH key at $SSH_KEY_PATH"
  
  # Create .ssh directory if it doesn't exist
  mkdir -p "$(dirname "$SSH_KEY_PATH")"
  
  if [ -f "$SSH_KEY_PATH" ]; then
    if [ "$FORCE_OVERWRITE" = "true" ]; then
      log_warning "Overwriting existing SSH key at $SSH_KEY_PATH"
    else
      log_info "Using existing SSH key at $SSH_KEY_PATH"
      return
    fi
  fi
  
  log_info "Generating a new SSH key"
  ssh-keygen -t ed25519 -C "$GITHUB_EMAIL" -f "$SSH_KEY_PATH" -N ""
  
  # Start the ssh-agent and add the key
  eval "$(ssh-agent -s)"
  ssh-add "$SSH_KEY_PATH"
  
  log_success "SSH key generated successfully"
}

# Upload SSH key to GitHub
upload_key_to_github() {
  local ssh_key_path="$SSH_KEY_PATH.pub"
  
  # Read the public key
  if [ ! -f "$ssh_key_path" ]; then
    log_error "Public key file not found at $ssh_key_path"
    exit 1
  fi
  
  # Generate a key title using hostname and date
  local hostname=$(hostname)
  local date_str=$(date +"%Y-%m-%d")
  local key_title="$hostname-$date_str-auto"
  
  local public_key=$(cat "$ssh_key_path")
  
  # Create a JSON payload
  log_info "Uploading SSH key to GitHub"
  
  local response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -d "{\"title\":\"$key_title\",\"key\":\"$public_key\"}" \
    "https://api.github.com/user/keys")
  
  # Extract the HTTP status code and response body
  local status_code=$(echo "$response" | tail -n1)
  local response_body=$(echo "$response" | sed '$d')
  
  # Check for different types of errors
  if [ "$status_code" = "401" ]; then
    log_error "Authentication Error (401): Bad credentials"
    log_error "GitHub token was rejected. Please check your token."
    exit 1
  elif [ "$status_code" = "422" ]; then
    log_warning "Key may already exist on GitHub (422 response)"
    # Continue anyway - this might be a reboot with same key
  elif [ "$status_code" != "201" ]; then
    log_error "Error uploading key (HTTP $status_code): $response_body"
    exit 1
  else
    log_success "SSH key uploaded to GitHub successfully"
  fi
}

# Test SSH connection to GitHub
test_github_connection() {
  log_info "Testing connection to GitHub"
  
  # Create ~/.ssh directory if it doesn't exist
  mkdir -p ~/.ssh
  
  # Add GitHub to known hosts to avoid the prompt
  ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts 2>/dev/null
  
  # Test the connection (use -o BatchMode=yes to prevent interactive prompts)
  if ssh -o BatchMode=yes -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    log_success "Connection to GitHub successful"
    return 0
  else
    log_warning "Connection to GitHub might have issues. This is normal if the key was just added."
    log_warning "GitHub may need a few minutes to process your new SSH key."
    return 0
  fi
}

# Add your custom initialization tasks here
run_additional_tasks() {
  if [ "$RUN_ADDITIONAL_TASKS" != "true" ]; then
    log_info "Skipping additional tasks (RUN_ADDITIONAL_TASKS=$RUN_ADDITIONAL_TASKS)"
    return
  fi
  
  log_info "Running additional initialization tasks"
  
  # Update system packages
  log_info "Installing neovim"
  apt-get update && apt-get install -y neovim
  
  # Clone dotfiles and set up neovim
  log_info "Setting up neovim config"
  mkdir -p ~/.config
  cd ~/.config
  if [ ! -d "dotfiles" ]; then
    git clone "$DOTFILES_REPO_SSH_URL" dotfiles
  fi
  if [ ! -d "nvim" ]; then
    mv dotfiles/nvim .
  fi
  
  # Clone project repository
  log_info "Cloning project repository"
  cd ~
  if [ ! -d "cephalometry" ]; then
    git clone "$PROJECT_REPO_SSH_URL"
  fi
  
  log_success "Additional tasks completed"
}

# Main function
main() {
  # Store environment variables
  env > /etc/environment
  mkdir -p ${DATA_DIRECTORY:-/workspace/}
  
  display_header
  validate_config
  check_dependencies
  
  # GitHub SSH key setup
  generate_ssh_key
  upload_key_to_github
  test_github_connection
  
  # Run additional setup tasks
  run_additional_tasks
  
  log_success "Node initialization completed successfully"
}

# Run the main function
main

