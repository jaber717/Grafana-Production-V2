# Simple Zabbix Interface Traffic Dashboard

One dashboard, no NetFlow, Akvorado, or ClickHouse. Uses the existing Grafana Zabbix datasource and SNMP interface traffic items already collected by Zabbix.

## Import
Grafana → Dashboards → New → Import → upload `network-interface-traffic.json` and select the existing Zabbix datasource. Choose Device, Interface and time range.

## Data assumptions
Zabbix item names must contain `Bits received` / `Bits sent` (or `Incoming traffic` / `Outgoing traffic`). The interface dropdown extracts interface names from inbound item names. If your actual Zabbix item names differ, adjust the two item filters and the interface variable regex after checking Zabbix Latest data. The displayed unit assumes item values are in bits/second; do not use raw byte counters without preprocessing to a rate.

This is an importable initial version, **not live-tested** against the production Zabbix datasource. No production files or existing dashboards were modified.
