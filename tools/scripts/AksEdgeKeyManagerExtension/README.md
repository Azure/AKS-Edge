# AksEdge KeyManager Extension setup scrip

This directory contains the script use to setup the K3 configuration for AKS Edge Essential for Key Manager Extension.

## UpdateK3sConfigForKeyManager.ps1
 This script updates the k3s configuration to set the lifespan of a Service Account token to 24 hours. 
 This only needs to be run once prior to install the KeyManaget extension for the first time.