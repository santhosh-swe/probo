#!/usr/bin/env bash
# Verify FERPA framework imports end-to-end against a running probod.
set -euo pipefail

BASE="http://localhost:8080"
CONNECT="$BASE/api/connect/v1/graphql"
CONSOLE="$BASE/api/console/v1/graphql"
CJ="$(mktemp)"
FERPA_JSON="/home/user/probo/apps/console/public/data/frameworks/FERPA.json"

SUFFIX="$(date +%s)"
EMAIL="ferpa-${SUFFIX}@e2e.probo.test"
PASS="TestPassword123!"
NAME="FERPA Tester"

jqget() { python3 -c "import sys,json;d=json.load(sys.stdin);print(eval(sys.argv[1]))" "$1"; }

post_json() { # $1=url $2=json
  curl -sS -c "$CJ" -b "$CJ" -H "Content-Type: application/json" -X POST "$1" -d "$2"
}

echo "==> 1. signUp ($EMAIL)"
R=$(post_json "$CONNECT" "$(python3 - "$EMAIL" "$PASS" "$NAME" <<'PY'
import json,sys
e,p,n=sys.argv[1:4]
print(json.dumps({"query":"mutation($i:SignUpInput!){signUp(input:$i){identity{id}}}","variables":{"i":{"email":e,"password":p,"fullName":n}}}))
PY
)")
echo "$R"
echo "$R" | python3 -c "import sys,json;d=json.load(sys.stdin);assert not d.get('errors'),d['errors'];print('   user:',d['data']['signUp']['identity']['id'])"

echo "==> 2. createOrganization"
R=$(post_json "$CONNECT" "{\"query\":\"mutation(\$i:CreateOrganizationInput!){createOrganization(input:\$i){organization{id name}}}\",\"variables\":{\"i\":{\"name\":\"FERPA Test Org ${SUFFIX}\"}}}")
echo "$R"
ORG=$(echo "$R" | python3 -c "import sys,json;d=json.load(sys.stdin);assert not d.get('errors'),d['errors'];print(d['data']['createOrganization']['organization']['id'])")
echo "   org: $ORG"

echo "==> 3. assumeOrganizationSession"
R=$(post_json "$CONNECT" "$(python3 - "$ORG" "$BASE" <<'PY'
import json,sys
org,base=sys.argv[1:3]
print(json.dumps({"query":"mutation($i:AssumeOrganizationSessionInput!){assumeOrganizationSession(input:$i){result{... on OrganizationSessionCreated{session{id}}}}}","variables":{"i":{"organizationId":org,"continue":base}}}))
PY
)")
echo "$R"

echo "==> 4. importFramework (upload FERPA.json)"
OPS=$(python3 - "$ORG" <<'PY'
import json,sys
org=sys.argv[1]
q="mutation($input:ImportFrameworkInput!){importFramework(input:$input){frameworkEdge{node{id name controls(first:0){totalCount}}}}}"
print(json.dumps({"query":q,"variables":{"input":{"organizationId":org,"file":None}}}))
PY
)
R=$(curl -sS -c "$CJ" -b "$CJ" -X POST "$CONSOLE" \
  -F "operations=$OPS" \
  -F 'map={"0":["variables.input.file"]}' \
  -F "0=@${FERPA_JSON};type=application/json;filename=FERPA.json")
echo "$R"
echo "$R" | python3 -c "
import sys,json
d=json.load(sys.stdin)
assert not d.get('errors'),d['errors']
node=d['data']['importFramework']['frameworkEdge']['node']
print('   framework:',node['name'],'id=',node['id'])
print('   controls totalCount =',node['controls']['totalCount'])
assert node['controls']['totalCount']==29, 'expected 29 controls'
print('   ✅ FERPA imported with 29 controls')
"

echo "==> 5. read back a few controls"
R=$(post_json "$CONSOLE" "$(python3 - "$ORG" <<'PY'
import json,sys
org=sys.argv[1]
q="query($o:ID!){node(id:$o){... on Organization{frameworks(first:20){edges{node{id name controls(first:5){totalCount edges{node{name}}}}}}}}}"
print(json.dumps({"query":q,"variables":{"o":org}}))
PY
)")
echo "$R" | python3 -c "
import sys,json
d=json.load(sys.stdin)
fws=d['data']['node']['frameworks']['edges']
for e in fws:
    n=e['node']
    print('   -',n['name'],'(',n['controls']['totalCount'],'controls); sample:',[c['node']['name'] for c in n['controls']['edges'][:3]])
"
echo "DONE"
