#!/bin/bash

while (( "$#" )); do
  case "$1" in
    -s|--subscription)
      subscription=$2
      shift 2
      ;;
    -n|--name)
      appName=$2
      shift 2
      ;;
    -g|--resource-group)
      RG=$2
      shift 2
      ;;
    -h|--help)
      echo "Usage: ./deploy_application.sh -n {App Name} -g {Resource Group} -p {Primary Location} -s {Secondary Location} -v {Version. Default=1.0}"
      exit 0
      ;;
    -v|--version)
      version=$2
      shift 2
      ;;
    --) 
      shift
      break
      ;;
    -*|--*=) 
      echo "Error: Unsupported flag $1" >&2
      exit 1
      ;;
  esac
done

acrAccountName=acr${appName}001
cosmosDBAccountName=db${appName}001
eventHubNameSpace=hub${appName}001
redisName=cache${appName}001
storageAccountName=${appName}sa001
appInsightsName=ai${appName}001

az account show  >> /dev/null 2>&1
if [[ $? -ne 0 ]]; then
  az login
fi

if [[ -z "${version}" ]]; then
  version="1.0"
fi 

#Set Subscription and login into ACR
az account set -s ${subscription}
az acr login -n ${acrAccountName}

## Get Cosmos Connection String
cosmosConnectionString=`az cosmosdb list-connection-strings -n ${cosmosDBAccountName} -g ${RG} --query 'connectionStrings[0].connectionString' -o tsv`
cosmosEncoded=`echo -n ${cosmosConnectionString} | base64 -w 0`

## Get Event Hub Connection String 
eventHub=events
ehConnectionString=`az eventhubs namespace authorization-rule keys list -g ${RG} --namespace-name ${eventHubNameSpace} --name RootManageSharedAccessKey -o tsv --query primaryConnectionString`
eventHubEncoded=`echo -n "${ehConnectionString};EntityPath=${eventHub}" | base64 -w 0`

## Get Redis Connection String
redisKey=`az redis list-keys  -g ${RG} -n ${redisName} -o tsv --query primaryKey`
redisConnectionString=${redisName}.redis.cache.windows.net:6380,password=${redisKey},ssl=True,abortConnect=False
redisEncoded=`echo -n ${redisConnectionString} | base64 -w 0`

## Get Azure Storage Connection String
storageKey=`az storage account keys list -n ${storageAccountName} --query '[0].value' -o tsv`
storageConnectionString="DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageKey}"
storageEncoded=`echo -n "${storageConnectionString};EndpointSuffix=core.windows.net" | base64 -w 0`

## Get Application Insight Key
instrumentationKey=`az monitor app-insights component  show --app ${appInsightsName} -g ${RG} --query instrumentationKey -o tsv`
instrumentationKeyEncoded=`echo -n ${instrumentationKey} | base64 -w 0`

cd ..
cwd=`pwd`

cd Source/api
docker build -t ${acrAccountName}.azurecr.io/cqrs/api:${version} .
docker push ${acrAccountName}.azurecr.io/cqrs/api:${version}
cd ${cwd}

cd Source/eventprocessor
docker build -t ${acrAccountName}.azurecr.io/cqrs/eventprocessor:${version} .
docker push ${acrAccountName}.azurecr.io/cqrs/eventprocessor:${version} 
cd ${cwd}

cd Deployment
helm upgrade --install \
    --set acr_name=${acrAccountName} \
    --set AzureWebJobsStorage=${storageEncoded} \
    --set EVENTHUB_CONNECTIONSTRING=${eventHubEncoded} \
    --set COSMOSDB_CONNECTIONSTRING=${cosmosEncoded} \
    --set REDISCACHE_CONNECTIONSTRING=${redisEncoded} \
    --set APPINSIGHTS_INSTRUMENTATIONKEY=${instrumentationKeyEncoded} \
    --set api_version=${version} \
    --set eventprocessor_version=${version} \
    cqrs .