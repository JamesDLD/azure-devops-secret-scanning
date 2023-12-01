#!/usr/bin/env bash

set -e

#-------------------------------------------------------------------------
# Description: Send custom event telemetry to an Azure Application Insights instance.
#--------------------------------------------------------------------------
usage() {
    echo "usage: $0 -s <ConnectionString> -n <EventName> -c <CustomProperties>" 1>&2
    echo "where:" 1>&2
    echo "<ConnectionString>: Specify the connection string of your Azure Application Insights instance. This is the recommended method as it will point to the correct region and the the instrumentation key method support will end, see https://learn.microsoft.com/azure/azure-monitor/app/migrate-from-instrumentation-keys-to-connection-strings?WT.mc_id=AZ-MVP-5003548." 1>&2
    echo "<EventName>: Specify the name of your custom event." 1>&2
    echo "<CustomProperties>: Custom event." 1>&2
}

while getopts 's:n:c:' OPTS; do
	case "$OPTS" in
		s)
		  redacted="$(echo "$OPTARG" | cut -c1-27)-redacted"
		  echo "Using the connection string [$redacted] provided as input of this script"
			ConnectionString="$OPTARG"
			;;
		n)
		  echo "Using the custom event name [$OPTARG] provided as input of this script"
			EventName="$OPTARG"
			;;
		c)
		  echo "Using the base64 json [$OPTARG]"
			CustomProperties=$(echo "$OPTARG" | base64 -d)
			;;
		*)
			usage
			exit 1
			;;
	esac
done

# App Insights has an endpoint where all incoming telemetry is processed.
# The reference documentation is available here: https://learn.microsoft.com/azure/azure-monitor/app/api-custom-events-metrics?WT.mc_id=AZ-MVP-5003548
for ConnectionStringItem in $(echo "$ConnectionString" | tr ';' ' '); do
    Key=$(echo "$ConnectionStringItem" | cut -d "=" -f 1)
    Value=$(echo "$ConnectionStringItem" | cut -d "=" -f 2)
    if [[ "$Key" == "InstrumentationKey" ]]; then
      InstrumentationKey=$Value
    elif [[ "$Key" == "IngestionEndpoint" ]]; then
      IngestionEndpoint=$Value
    elif [[ "$Key" == "LiveEndpoint" ]]; then
      LiveEndpoint=$Value
    fi
done

Map=$( jq -n                              \
          --arg ik "$InstrumentationKey"  \
          --arg ie "$IngestionEndpoint"   \
          --arg le "$LiveEndpoint"        \
          '{
              InstrumentationKey: $ik,
              IngestionEndpoint: $ie,
              LiveEndpoint: $le
            }' )

AppInsightsIngestionEndpoint="$(echo $Map | jq -r '.IngestionEndpoint')v2/track"
InstrumentationKey=$(echo $Map | jq -r '.InstrumentationKey')
Date=`date -u +%FT%T`

# Prepare the REST request body schema.
# NOTE: this schema represents how events are sent as of the app insights .net client library v2.9.1.
# Newer versions of the library may change the schema over time and this may require an update to match schemas found in newer libraries.

Tags=$( jq -n                                     \
          --arg hn "$HOSTNAME"                    \
          '{
              roleInstance: $hn,
              sdkVersion: "BashUtilityFunctions",
            }' )

BaseData=$( jq  -n                                \
                --arg ev "$EventName"             \
                --argjson cp "$CustomProperties"  \
                '{
                   var: "2",
                   name: $ev,
                   properties: $cp
                }' )

Data=$( jq -n                       \
           --argjson bd "$BaseData" \
           '{
               baseType: "EventData",
               baseData: $bd,
             }' )

BodyObject=$( jq  -n \
                  --arg na "Microsoft.ApplicationInsights.$InstrumentationKey.Event"  \
                  --arg da "$Date"                                                    \
                  --arg ik "$InstrumentationKey"                                      \
                  --argjson tg "$Tags"                                                \
                  --argjson dt "$Data"                                                \
                  '{
                      name: $na,
                      time: $da,
                      iKey: $ik,
                      tags: $tg,
                      data: $dt,
                    }' )

echo $BodyObject | curl --request POST $AppInsightsIngestionEndpoint        \
                        --header 'Content-Type: application/x-json-stream'  \
                        --silent                                            \
                        --output /dev/null                                  \
                        --data @-
