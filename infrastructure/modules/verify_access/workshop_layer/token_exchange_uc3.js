// IVIA OAuth Mapping Rule — UC3 Token Exchange
//
// Fires on grant_type=urn:ietf:params:oauth:grant-type:token-exchange against
// the WorkshopCibaDef. Augments the resulting access token with:
//   - may_act          (RFC 8693)  : actor identity allowed to act on subject's behalf
//   - authorization_details (RFC 9396 RAR) : preserved refund_approval payload
//
// The CIBA-approved access token already carries `sub` (the approving user).
// Token-exchange swaps the CIBA token for one whose subject is the agent
// service account but whose `may_act` retains the original `sub` — i.e., the
// agent acts WITH the user's authority, not AS the user.

importPackage(Packages.com.tivoli.am.fim.trustserver.sts);
importPackage(Packages.com.tivoli.am.fim.trustserver.sts.uuser);
importPackage(Packages.com.tivoli.am.fim.trustserver.sts.utilities);

var grantType = stsuu.getContextAttributes().getAttributeValueByName("grant_type");
if (grantType != null && grantType.equals("urn:ietf:params:oauth:grant-type:token-exchange")) {

    // Original subject (from the CIBA-approved subject_token) becomes may_act.sub
    var origSub = stsuu.getPrincipalName();
    if (origSub != null) {
        var mayActJson = '{"sub":"' + origSub + '"}';
        stsuu.addAttribute(new Attribute(
            "may_act",
            "urn:ibm:names:ITFIM:5.1:accessmanager",
            mayActJson));
        IDMappingExtUtils.traceString("[token_exchange_uc3] may_act set to " + mayActJson);
    }

    // Preserve authorization_details across the exchange (RFC 9396 RAR).
    // CIBA bc-authorize request carried it; restore on the exchanged token.
    var authDetails = stsuu.getContextAttributes().getAttributeValueByName("authorization_details");
    if (authDetails != null) {
        stsuu.addAttribute(new Attribute(
            "authorization_details",
            "urn:ibm:names:ITFIM:5.1:accessmanager",
            authDetails));
        IDMappingExtUtils.traceString("[token_exchange_uc3] authorization_details preserved");
    }

    // Exchanged-token subject = agent service account.
    stsuu.setPrincipalName("service-account:agent-uc3");
}
