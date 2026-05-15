-- Start "/workspace/src/appliance/app-core/modules/files/hvdb.sql"
-- Start "/workspace/src/appliance/app-core/modules/files/common.sql"
-- --------------- Begin Copyright -----------------------------------------
--
--  IBM Confidential 
--  PID 5725-V89 5725-V90 5737-F02
--
--  Copyright IBM Corp. 2016, 2024
--
-- --------------- End Copyright -------------------------------------------














-- ------------------
-- Schema: PostgreSQL
-- Build: OnPremise
-- ------------------



-- End "/workspace/src/appliance/app-core/modules/files/common.sql"


CREATE OR REPLACE FUNCTION lcase(str character varying) RETURNS character varying
LANGUAGE sql IMMUTABLE
AS $_$
SELECT LOWER($1)
$_$;

-- Start "/workspace/src/appliance/app-core/modules/files/isam_access_control_generic_update_201601010.sql"

-- @component: UPDATE
-- @description: This table holds data related to each hvdb database schema update performed as part of an Appliance upgrade.
-- @field [DSU_INSTALL_DATE]: The date the schema update was performed.
-- @field [DSU_VERSION]: The version of the schema update as dictated by the update file.
-- @field [DSU_FILE]: The filename of the script which performed the schema updates.

CREATE TABLE HVDB_SCHEMA_UPDATES (
    DSU_INSTALL_DATE  TIMESTAMP NOT NULL,
    DSU_VERSION       INTEGER NOT NULL,
    DSU_FILE          VARCHAR(256) NOT NULL
);
COMMIT;
INSERT INTO HVDB_SCHEMA_UPDATES VALUES(CURRENT_TIMESTAMP,202512019,'Install');
COMMIT;
-- End "/workspace/src/appliance/app-core/modules/files/isam_access_control_generic_update_201601010.sql"
-- Start "/workspace/src/appliance/app-core/modules/files/isam_access_control_generic_update_201606290.sql"

-- @component: SCIM
-- @description: This table has been marked for deprecation.
-- @field [EXT_UID]: This table has been marked for deprecation.
-- @field [USER_SHORTNAME]: This table has been marked for deprecation.
-- @field [CFGID]: This table has been marked for deprecation.
CREATE TABLE SCIM_EAS_EXT_USERS (
	  EXT_UID VARCHAR(64) NOT NULL,
	  USER_SHORTNAME VARCHAR(64) NOT NULL,
	  CFGID INTEGER NOT NULL,
	    UNIQUE (EXT_UID),
	  CONSTRAINT SCIM_EAS_EXT_USER_PK PRIMARY KEY (EXT_UID, USER_SHORTNAME)
);

-- @component: SCIM
-- @description: This table has been marked for deprecation.
-- @field [EXT_MID]: This table has been marked for deprecation.
-- @field [EXT_UID]: This table has been marked for deprecation.
-- @field [SCIM_SCHEMA]: This table has been marked for deprecation.
CREATE TABLE SCIM_EAS_EXT_METHODS (
	  EXT_MID VARCHAR(64) NOT NULL,
	  EXT_UID VARCHAR(64) NOT NULL,
	  SCIM_SCHEMA VARCHAR(256) NOT NULL,
	  CONSTRAINT SCIM_EAS_EXT_METH_PK PRIMARY KEY (EXT_MID),
	  FOREIGN KEY (EXT_UID) REFERENCES SCIM_EAS_EXT_USERS(EXT_UID) ON DELETE CASCADE
);

COMMIT;
-- End "/workspace/src/appliance/app-core/modules/files/isam_access_control_generic_update_201606290.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/rba-hvdb.sql"


-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/rba_hvdb_schema.sql"


-- @component: RBA
-- @description: This table holds data on each of devices that have been registered with RBA.
--               Current indexes: (LAST_USED_TIME)
-- @field [DEVICE_ID]: The identifier field for this table.
-- @field [DEVICE_NAME]: The device's name, as supplied by the user.
-- @field [IS_ENABLED]: A boolean representation of whether the device is enabled. 0 == true, anything else == false.
-- @field [LAST_USED_TIME]: The timestamp that represents when this device was last used.
-- @field [TENANT_ID]: The name of the tenant that this device is registered against. Typically, will be 'amapp-runtime'.
CREATE TABLE RBA_DEVICE (
  DEVICE_ID       BYTEA NOT NULL,
  DEVICE_NAME     VARCHAR(200) NOT NULL,
  IS_ENABLED      SMALLINT  DEFAULT 0,
  LAST_USED_TIME  TIMESTAMP    NOT NULL ,
  TENANT_ID      VARCHAR(200),

  CONSTRAINT D_PK PRIMARY KEY (DEVICE_ID)
);

CREATE INDEX DEV_LAST_USED_TIME ON RBA_DEVICE(LAST_USED_TIME);


-- @component: RBA
-- @description: This table holds data on each attribute that makes up a fingerprint of a device that is registered to RBA.
--               Current indexes: PostgreSQL: (btree(DEVICE_ID))
-- @field [DEVICE_ID]: The identifier of the device this fingerprint attribute is related to. A foreign key to the DEVICE_ID of the RBA_DEVICE table.
-- @field [ATTR_ID]: The identifier of the attribute.
-- @field [VALUE]: The value of this fingerprint attribute.
-- @field [TENANT_ID]: The name of the tenant that this fingerprint attribute is registered for. Typically, will be 'amapp-runtime'.
CREATE TABLE RBA_DEVICE_FINGERPRINT (
  DEVICE_ID  BYTEA         NOT NULL,
  ATTR_ID    BIGINT        NOT NULL,
  VALUE      VARCHAR(2000) NOT NULL,
  TENANT_ID  VARCHAR(200),

  CONSTRAINT DF_PK  PRIMARY KEY (DEVICE_ID, ATTR_ID),
  CONSTRAINT DF_FK2 FOREIGN KEY (DEVICE_ID) REFERENCES RBA_DEVICE(DEVICE_ID) ON DELETE CASCADE
);

CREATE INDEX rdf_ix0 ON rba_device_fingerprint USING btree (device_id);


-- @component: RBA
-- @description: This table holds data on each user with a device that is registered to RBA.
--               Current indexes: PostgreSQL: (btree(DEVICE_ID)) Other DBs: (DEVICE_ID)
-- @field [USER_ID]: The identifier for the user that the device is registered to.
-- @field [DEVICE_ID]: The identifier for the device that is registered to the user. A foreign key to the DEVICE_ID of the RBA_DEVICE table.
-- @field [TENANT_ID]: The name of the tenant that this user device is registered for. Typically, will be 'amapp-runtime'.
CREATE TABLE RBA_USER_DEVICE (
  USER_ID    VARCHAR(200) NOT NULL,
  DEVICE_ID  BYTEA        NOT NULL,
  TENANT_ID  VARCHAR(200),

  CONSTRAINT UD_PK PRIMARY KEY (USER_ID, DEVICE_ID),
  CONSTRAINT UD_FK FOREIGN KEY (DEVICE_ID) REFERENCES RBA_DEVICE(DEVICE_ID) ON DELETE CASCADE
);

CREATE INDEX rud_ix0 ON rba_user_device USING btree (device_id);


-- @component: RBA
-- @description: This table holds data on each CBA session attribute for a user.
--               Current indexes: (REC_TIME)
-- @field [REC_TIME]: The time that this session attribute was recorded.
-- @field [USER_UUID]: The user id of the user that this session attribute is associated with.
-- @field [SESSION_ID]: The session id of the session that this attribute is associated with. Stored as a randomly generated UUID.
-- @field [TENANT_ID]: The name of the tenant that this user session attribute is associated with. Typically, will be 'amapp-runtime'.
CREATE TABLE RBA_USER_ATTR_SESSION (
 REC_TIME    TIMESTAMP    NOT NULL ,
 USER_UUID   VARCHAR(200) NOT NULL,
 SESSION_ID  BYTEA        NOT NULL,
 TENANT_ID   VARCHAR(200),

 CONSTRAINT UAS_PK PRIMARY KEY (SESSION_ID),
 CONSTRAINT UAS_UK UNIQUE  (USER_UUID)
);

CREATE INDEX UAS_REC_TIME ON RBA_USER_ATTR_SESSION(REC_TIME);


-- @component: RBA
-- @description: This table holds data and values on each user session attribute.
--               Current indexes: All DBs: (REC_TIME) PostgreSQL: (btree(SESSION_ID))
-- @field [REC_TIME]: The time that this session attribute was recorded.
-- @field [SESSION_ID]: The session id of the session that this attribute is associated with. Stored as a randomly generated UUID. A foreign key to the SESSION_ID of the RBA_USER_ATTR_SESSION table.
-- @field [ATTR_ID]: The attribute id of the attribute that this session data is associated with.
-- @field [SOURCE]: The name of the source for where the attribute came from.
-- @field [IS_TRUSTED]: A value to indicate whether this session attribute is trusted or not. 0 == trusted, 1 == not trusted.
-- @field [VALUE]: The value of this user session attribute.
CREATE TABLE RBA_USER_ATTR_SESSION_DATA (
 REC_TIME    TIMESTAMP     NOT NULL ,
 SESSION_ID  BYTEA         NOT NULL,
 ATTR_ID     BIGINT        NOT NULL,
 SOURCE      VARCHAR(400),
 IS_TRUSTED  SMALLINT DEFAULT 0,
 VALUE       VARCHAR(2000) NOT NULL,

 CONSTRAINT UASD_PK PRIMARY KEY (SESSION_ID, ATTR_ID),
 CONSTRAINT UASD_FK1 FOREIGN KEY (SESSION_ID) REFERENCES RBA_USER_ATTR_SESSION (SESSION_ID) ON DELETE CASCADE
);

CREATE INDEX ruasd_ix0 ON rba_user_attr_session_data USING btree (session_id);


CREATE INDEX UASD_REC_TIME ON RBA_USER_ATTR_SESSION_DATA(REC_TIME);

-- @component: RBA
-- @description: This table holds data and values on usage data for a user.
--               Current indexes: All DBs: (USER_ID)
-- @field [SESSION_ID]: The session id of the session that this usage data is associated with. Stored as a randomly generated UUID.
-- @field [REC_TIME]: The time that this usage data was recorded.
-- @field [USER_ID]: The user id of the user that this usage data is associated with.
-- @field [ATTR_ID]: The attribute id of the attribute that this usage data is associated with.
-- @field [VALUE]: The value of the usage data.
-- @field [TENANT_ID]: The name of the tenant that this usage data is associated with. Typically, will be 'amapp-runtime'.
CREATE TABLE RBA_USER_USAGE_DATA (
  SESSION_ID  BYTEA         NOT NULL,
  REC_TIME    TIMESTAMP     NOT NULL ,
  USER_ID     VARCHAR(200)  NOT NULL,
  ATTR_ID     BIGINT        NOT NULL,
  VALUE       VARCHAR(2000) NOT NULL,
  TENANT_ID   VARCHAR(200),

  CONSTRAINT UUD_PK PRIMARY KEY (SESSION_ID,REC_TIME, USER_ID,ATTR_ID)
);

CREATE INDEX UUD_USER_ID ON RBA_USER_USAGE_DATA(USER_ID);


-- @component: RBA
-- @description: This table holds information about user data that has been cleaned during a DB cleanup.
-- @field [DATE_REMOVED]: The time/date that the user data was removed from the DB.
-- @field [DATA_REMOVED]: A description of the data removed from the DB. Will be either 'userData' or 'userDevices'.
-- @field [ROWS_DELETED]: The number of rows that were deleted.
CREATE TABLE RBA_RTE_DB_MAINTENANCE_META (
  DATE_REMOVED  TIMESTAMP   ,
  DATA_REMOVED  VARCHAR(30),
  ROWS_DELETED  BIGINT DEFAULT 0,

  CONSTRAINT RDBM_PK   PRIMARY KEY (DATE_REMOVED)
);


-- @component: RBA
-- @description: This table holds data on transactions obligation and their request.
--               Current indexes: (REC_TIME)
-- @field [TXN_ID]: The identifier for the transaction.
-- @field [REC_TIME]: The time that this transaction obligation data was recorded.
-- @field [OBLIGATION_URI]: The URI of the obligation that this transaction data is associated with.
-- @field [REQUESTED_URL]: The request URL that was used to fire the obligation.
-- @field [ACTION_ID]: The identifier of the action associated with this transaction.
CREATE TABLE AUTH_TXN_OBL_DATA (
  TXN_ID          BYTEA         NOT NULL,
  REC_TIME        TIMESTAMP     NOT NULL,
  OBLIGATION_URI  VARCHAR(200)  NOT NULL,
  REQUESTED_URL   VARCHAR(4000) NOT NULL,
  ACTION_ID       VARCHAR(200)  NOT NULL,

  CONSTRAINT TXID_PK  PRIMARY KEY (TXN_ID)
);

CREATE INDEX AUTX_REC_TIME ON AUTH_TXN_OBL_DATA(REC_TIME);


-- @component: RBA
-- @description: This table holds data on a transactions obligation parameters.
--               Current indexes: PostgreSQL: btree(TXN_ID)
-- @field [TXN_ID]: The identifier for the transaction. A foreign key to the TXN_ID of the AUTH_TXN_OBL_DATA table.
-- @field [OBLIGATION_PARAM_NAME]: The name of the obligation parameter.
-- @field [OBLIGATION_PARAM_VALUE]: The value of the obligation parameter.
-- @field [OBLIGATION_PARAM_DATATYPE]: The data type of the obligation parameter. ('String','Double','Date','Time','Integer','X500Name','Boolean')
CREATE TABLE AUTH_TXN_OBL_PARAMETERS_DATA (
  TXN_ID                     BYTEA         NOT NULL,
  OBLIGATION_PARAM_NAME      VARCHAR(200)  NOT NULL,
  OBLIGATION_PARAM_VALUE     VARCHAR(2000) NOT NULL,
  OBLIGATION_PARAM_DATATYPE  VARCHAR(200)  NOT NULL,

  CONSTRAINT TXPID_PK  PRIMARY KEY (TXN_ID, OBLIGATION_PARAM_NAME),
  CONSTRAINT TXOV_FK1 FOREIGN KEY (TXN_ID) REFERENCES AUTH_TXN_OBL_DATA(TXN_ID) ON DELETE CASCADE,
  CONSTRAINT PA_DATATYPE CHECK (OBLIGATION_PARAM_DATATYPE IN ('String', 'Double', 'Date', 'Time', 'Integer', 'X500Name', 'Boolean'))
);

CREATE INDEX atopd_ix0 ON auth_txn_obl_parameters_data USING btree (txn_id);


-- @component: RBA
-- @description: This table holds data on a transactions obligation context attributes.
--               Current indexes: PostgreSQL: btree(TXN_ID)
-- @field [TXN_ID]: The identifier for the transaction. A foreign key to the TXN_ID of the AUTH_TXN_OBL_DATA table.
-- @field [CTX_ATTR_NAME]: The name of the context attribute.
-- @field [CTX_ATTR_URI]: The URI of the context attribute.
-- @field [CTX_ATTR_ISSUER]: The issuer of the context attribute.
-- @field [CTX_ATTR_DATATYPE]: The data type of the context attribute. ('String','Double','Date','Time','Integer','X500Name','Boolean')
-- @field [CTX_ATTR_VALUE_ID]: The identifier for the context attribute value row.
CREATE TABLE AUTH_TXN_OBL_CTX_ATTRS_DATA (
  TXN_ID             BYTEA        NOT NULL,
  CTX_ATTR_NAME      VARCHAR(200) NOT NULL,
  CTX_ATTR_URI       VARCHAR(200) NOT NULL,
  CTX_ATTR_ISSUER    VARCHAR(200),
  CTX_ATTR_DATATYPE  VARCHAR(200) NOT NULL,
  CTX_ATTR_VALUE_ID  BYTEA        NOT NULL,

  CONSTRAINT TXAID_PK  PRIMARY KEY (TXN_ID, CTX_ATTR_NAME, CTX_ATTR_URI),
  CONSTRAINT TXOAV_FK1 FOREIGN KEY (TXN_ID) REFERENCES AUTH_TXN_OBL_DATA(TXN_ID) ON DELETE CASCADE,
  CONSTRAINT CA_DATATYPE CHECK (CTX_ATTR_DATATYPE IN ('String', 'Double', 'Date', 'Time', 'Integer', 'X500Name', 'Boolean')),
  CONSTRAINT VID_UK1 UNIQUE  (CTX_ATTR_VALUE_ID)
);

CREATE INDEX atocad_ix0 ON auth_txn_obl_ctx_attrs_data USING btree (txn_id);


-- @component: RBA
-- @description: This table holds the value of a transactions obligation context attribute.
--               Current indexes: PostgreSQL: btree(CTX_ATTR_VALUE_ID) Other DBs: CTX_ATTR_VALUE_ID
-- @field [CTX_ATTR_VALUE_ID]: The identifier for this context attribute value. A foreign key to the CTX_ATTR_VALUE_ID of the AUTH_TXN_OBL_CTX_ATTRS_DATA table.
-- @field [CTX_ATTR_VALUE]: The value of this context attribute.
CREATE TABLE AUTH_TXN_OBL_CTX_ATTRS_DATA_V (
 CTX_ATTR_VALUE_ID  BYTEA         NOT NULL,
 CTX_ATTR_VALUE     VARCHAR(2000) NOT NULL,

 CONSTRAINT TXUAV_FK1 FOREIGN KEY (CTX_ATTR_VALUE_ID) REFERENCES AUTH_TXN_OBL_CTX_ATTRS_DATA(CTX_ATTR_VALUE_ID) ON DELETE CASCADE
);

CREATE INDEX atocadv_ix0 ON auth_txn_obl_ctx_attrs_data_v USING btree (ctx_attr_value_id);


COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/rba_hvdb_schema.sql"

-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/rba-hvdb.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/fim-hvdb.sql"


-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/DistributedMap.sql"

-- @component: AAC
-- @description: This table is used to store longer lived data.
--               Current indexes: (DMAP_EXPIRY)
-- @field [DMAP_KEY]: The key into the map entry.
-- @field [DMAP_PARTITION]: The map to store this entry in.
-- @field [DMAP_VALUE]: The value to be stored.
-- @field [DMAP_EXPIRY]: The expiry of the entry in the map. Formatted as Unix time but in milliseconds.
CREATE TABLE DMAP_ENTRIES (
    DMAP_KEY        VARCHAR(256) NOT NULL,
    DMAP_PARTITION  VARCHAR(256) NOT NULL,
    DMAP_VALUE      TEXT         NOT NULL,
    DMAP_EXPIRY     BIGINT ,
    PRIMARY KEY (DMAP_KEY, DMAP_PARTITION)
);

CREATE INDEX DMAP_EXPIRY_INDEX ON DMAP_ENTRIES(DMAP_EXPIRY);


COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/DistributedMap.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/OAuthCacheProvider.sql"
-- @component: OAuth
-- @description: This table is used to store OAuth tokens. 
--               Current indexes: (STATE_ID), (TOKEN_STRING), (PREV_TOKEN_STRING), (LIFETIME), (USERNAME + CLIENT_ID)
-- @field [TOKEN_ID]: OAuth token id.This acts as a primary key in this table.
-- @field [TYPE]: The entry to store the type of OAuth token.
-- @field [SUB_TYPE]: The entry to store the sub type of OAuth token.
-- @field [DATE_CREATED]: The token creation timestamp.
-- @field [DATE_LAST_USED]: The last introspection time for the token.
-- @field [LIFETIME]: The time to live entry for generated token.
-- @field [TOKEN_STRING]: The entry to store OAuth token.
-- @field [CLIENT_ID]: OAuth application client id.
-- @field [USERNAME]: The entry to store the username.
-- @field [SCOPE]: The entry to store the scope.
-- @field [REDIRECT_URI]: The redirect uri of the OAuth application.
-- @field [STATE_ID]: The state id for an OAuth token transaction.
-- @field [TOKEN_ENABLED]: Entry to reflect whether the token is active or revoked.
-- @field [PREV_TOKEN_STRING]: Entry to enable multiple refresh token for fault tolerance.
CREATE TABLE OAUTH20_TOKEN_CACHE (
       TOKEN_ID          VARCHAR(512)    NOT NULL CONSTRAINT PK_LOOKUPKEY PRIMARY KEY,
       TYPE              VARCHAR(64)     NOT NULL,
       SUB_TYPE          VARCHAR(64),
       DATE_CREATED      BIGINT,
       DATE_LAST_USED    BIGINT,
       LIFETIME          INT,
       TOKEN_STRING      VARCHAR(512)    NOT NULL,
       CLIENT_ID         VARCHAR(256)    NOT NULL,
       USERNAME          VARCHAR(256)    NOT NULL,
       SCOPE             VARCHAR(512)    NOT NULL,
       REDIRECT_URI      VARCHAR(256),
       STATE_ID          VARCHAR(64)     NOT NULL,
       TOKEN_ENABLED     CHAR            NOT NULL,
       PREV_TOKEN_STRING VARCHAR(512),
        CHECK (TOKEN_ENABLED IN ('Y', 'N'))
);

CREATE INDEX OAUTH20CACHE_ST        ON OAUTH20_TOKEN_CACHE      (STATE_ID ASC);
CREATE INDEX OAUTH20CACHE_TKSTRING  ON OAUTH20_TOKEN_CACHE      (TOKEN_STRING);
CREATE INDEX OAUTH20CACHE_PTKSTRING  ON OAUTH20_TOKEN_CACHE      (PREV_TOKEN_STRING);
CREATE INDEX OAUTH20CACHE_LIFETIME  ON OAUTH20_TOKEN_CACHE      (LIFETIME ASC);
CREATE INDEX OAUTH20CACHE_UCID      ON OAUTH20_TOKEN_CACHE      (USERNAME, CLIENT_ID);

-- @component: OAuth
-- @description: This table is used to store OAuth clients. 
--               Current indexes: (USERNAME), Oracle explicit (USERNAME + CLIENT_ID)
-- @field [TRUSTED_CLIENT_ID]: The entry to store the decisions of a resource owner on which clients to trust. This also act as a primary key.
-- @field [USERNAME]: The username.
-- @field [CLIENT_ID]: OAuth application client id.
CREATE TABLE OAUTH_TRUSTED_CLIENT (
       TRUSTED_CLIENT_ID        VARCHAR(256) NOT NULL CONSTRAINT PK_UNIQUEID PRIMARY KEY,
       USERNAME                 VARCHAR(256) NOT NULL,
       CLIENT_ID                VARCHAR(256) NOT NULL
);

CREATE INDEX TRUSTEDCLIENTS_USERNAME            ON OAUTH_TRUSTED_CLIENT    (USERNAME);
CREATE INDEX TRUSTEDCLIENTS_USERNAMECLIENTID    ON OAUTH_TRUSTED_CLIENT    (USERNAME, CLIENT_ID);

-- @component: OAuth
-- @description: This table is used to store permitted scope of an authorized client. 
--               Current indexes: Postgres explicit (TRUSTED_CLIENT_ID)
-- @field [TRUSTED_CLIENT_ID]: The entry to store the decisions of a resource owner on which clients to trust. Foreign key for the TRUSTED_CLIENT_ID in OAUTH_TRUSTED_CLIENT table. 
-- @field [SCOPE]: The entry to store the permitted scopes
CREATE TABLE OAUTH_SCOPE (
       TRUSTED_CLIENT_ID    VARCHAR(256) NOT NULL,
       SCOPE                VARCHAR(256) NOT NULL,

       CONSTRAINT PK_UNIQUEIDSCOPE PRIMARY KEY (TRUSTED_CLIENT_ID, SCOPE),
       FOREIGN KEY (TRUSTED_CLIENT_ID) REFERENCES OAUTH_TRUSTED_CLIENT(TRUSTED_CLIENT_ID) ON DELETE CASCADE
);

CREATE INDEX as_ix0 ON oauth_scope USING btree (trusted_client_id);
-- @component: OAuth
-- @description: This table is used to store the additional information associated with an OAuth grant. 
--               Current indexes: (STATE_ID), (ATTR_NAME)
-- @field [STATE_ID]: The state id for an OAuth token transaction. 
-- @field [ATTR_NAME]: The entry is to store the key of the additional attributes.
-- @field [ATTR_VALUE]: value of the additional attributes.
-- @field [SENSITIVE]: The entry to specify if it is a SENSITIVE attribute.
-- @field [READ_ONLY]: The entry to specify if it is a read only attribute.
CREATE TABLE OAUTH20_TOKEN_EXTRA_ATTRIBUTE (
    STATE_ID    VARCHAR(256),
    ATTR_NAME   VARCHAR(256),
    ATTR_VALUE  VARCHAR(256),
    SENSITIVE   CHAR      DEFAULT 'N',
    READ_ONLY   CHAR      DEFAULT 'N',
     CHECK (SENSITIVE IN ('Y', 'N')),
     CHECK (READ_ONLY IN ('Y', 'N'))
);

-- Only create indexes if not Oracle since pk is created for Oracle within fim-hvdb.sql and this will 
-- give "free" indexes.
CREATE INDEX EXTRAATTR_STATE_ID ON OAUTH20_TOKEN_EXTRA_ATTRIBUTE (STATE_ID ASC);
CREATE INDEX EXTRAATTR_NAME     ON OAUTH20_TOKEN_EXTRA_ATTRIBUTE (ATTR_NAME ASC);

-- @component: OAuth
-- @description: This table is used to store the dynamic client details. 
--               Current indexes: (STATE_ID), (ATTR_NAME)
-- @field [CLIENT_ID]: Client id of the dynamic client. This is the primary key.
-- @field [DEFINITION_ID]: Id of the dynamic client definition.
-- @field [DEFINITION_NAME]: Name of the dynamic client definition.
-- @field [OWNER_USERNAME]: resource owner's username
-- @field [DYN_DATA]: Dynamic client registration data.
CREATE TABLE OAUTH20_DYNAMIC_CLIENT (
    CLIENT_ID     VARCHAR(256) NOT NULL CONSTRAINT DYN_PK_LOOKUPKEY PRIMARY KEY,
    DEFINITION_ID BIGINT NOT NULL,
    DEFINITION_NAME VARCHAR(200),
    OWNER_USERNAME VARCHAR(256),
    DYN_DATA      TEXT
);

CREATE INDEX OAUTH20DYNCLIENT_DEF    ON OAUTH20_DYNAMIC_CLIENT     (DEFINITION_ID);
CREATE INDEX OAUTH20DYNCLIENTS_USER  ON OAUTH20_DYNAMIC_CLIENT     (OWNER_USERNAME);


COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/OAuthCacheProvider.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/UserInfoProvider.sql"



-- @component: AAC
-- @description: This table contains attributes for a user.
--               Current indexes: (VALUES_ID)
-- @field [USER_ID]: The user Id for the user that this attribute is for.
-- @field [ATTRIBUTE_NAME]: The name of the attribute being assigned to a user.
-- @field [ATTRIBUTE_NAMESPACE]: The namespace of the attribute being assigned to a user.
-- @field [ATTRIBUTE_DATATYPE]: The data type of the attribute being assigned to a user. Possible values are: String, Double, Password, Long, Date, Time, Integer, X500Name.
-- @field [VALUES_ID]: The row identifier for the value entry of this attribute. Must be unique.
CREATE TABLE USER_ATTRIBUTES (
 USER_ID             VARCHAR(200) NOT NULL,
 ATTRIBUTE_NAME      VARCHAR(200) NOT NULL,
 ATTRIBUTE_NAMESPACE VARCHAR(200) NOT NULL,
 ATTRIBUTE_DATATYPE  VARCHAR(200) NOT NULL,
 VALUES_ID           BYTEA        NOT NULL,
 CONSTRAINT UA_PK PRIMARY KEY (USER_ID, ATTRIBUTE_NAME, ATTRIBUTE_NAMESPACE ),
 CONSTRAINT CHK_ATTR_DTYPE CHECK (ATTRIBUTE_DATATYPE IN ('String', 'Double', 'Password','Long', 'Date', 'Time', 'Integer', 'X500Name')),
 CONSTRAINT UA_UK1 UNIQUE  (VALUES_ID)
);


-- @component: AAC
-- @description: This table contains the values of the attributes described in the USER_ATTRIBUTES table.
--               Current indexes: (VALUES_ID)
-- @field [VALUES_ID]: The identifier for this attributes value. Foreign Key for VALUES_ID in the USER_ATTRIBUTES table. Primary Key for the table.
-- @field [VALUE]: The value of the attribute.
CREATE TABLE USER_ATTRIBUTES_VALUES (
 VALUES_ID   BYTEA      NOT NULL,
 VALUE       VARCHAR(2000) NOT NULL,
 CONSTRAINT UAV_FK1 FOREIGN KEY (VALUES_ID) REFERENCES USER_ATTRIBUTES(VALUES_ID) ON DELETE CASCADE
);


COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/UserInfoProvider.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201605015.sql"

-- @component: MMFA
-- @description: This table holds common data for all MMFA authenticators. It is a parent table for all other MMFA authenticator tables.
--               Current indexes: (USERNAME), (TENANT_ID)
-- @field [APP_INST_ID]: The identifier for this authenticator. Values are a generated UUID.
-- @field [TENANT_ID]: The name of the tenant that this authenticator is usable with. Typically, will be 'amapp-runtime'.
-- @field [USERNAME]: The ISAM username of the user associated with this authenticator.
CREATE TABLE AUTHENTICATORS (
       APP_INST_ID       VARCHAR(256)    NOT NULL,
       TENANT_ID         VARCHAR(256),
       USERNAME          VARCHAR(256)    NOT NULL,

       PRIMARY KEY (APP_INST_ID)
);

-- @component: MMFA
-- @description: This table holds data relating to an OAuth grant.
--               Current indexes: (STATE_ID)
-- @field [APP_INST_ID]: The identifier for this authenticator. Values are a generated UUID. A foreign key to the APP_INST_ID of the AUTHENTICATORS table.
-- @field [STATE_ID]: The Grant ID of this OAuth grant.
CREATE TABLE OAUTH_AUTHENTICATORS (
       APP_INST_ID       VARCHAR(256)   NOT NULL,
       STATE_ID          VARCHAR(64)    NOT NULL,

       PRIMARY KEY (APP_INST_ID),
       FOREIGN KEY (APP_INST_ID) REFERENCES AUTHENTICATORS(APP_INST_ID) ON DELETE CASCADE
);

-- @component: MMFA
-- @description: This table holds data relating to a generic MMFA authentication method which is enrolled against an authenticator
--               Current indexes: (APP_INST_ID)
-- @field [AUTH_METHOD_ID]: The identifier for this authentication method. Values are a generated UUID.
-- @field [APP_INST_ID]: The identifier of the authenticator that this authentication method is enrolled to. A foreign key to the APP_INST_ID of the AUTHENTICATORS table.
-- @field [TYPE]: The type of this authentication method. Typically, will be 'crypto'.
-- @field [ENABLED]: A String representation of the boolean value that indicates whether this authentication method is enabled or not.
CREATE TABLE REGISTERED_AUTH_METHODS (
       AUTH_METHOD_ID   VARCHAR(256)    NOT NULL,
       APP_INST_ID      VARCHAR(256)    NOT NULL,
       TYPE             VARCHAR(64)     NOT NULL,
       ENABLED          VARCHAR(64)     NOT NULL,

       PRIMARY KEY (AUTH_METHOD_ID),
       FOREIGN KEY (APP_INST_ID) REFERENCES AUTHENTICATORS(APP_INST_ID) ON DELETE CASCADE
);

-- @component: MMFA
-- @description: This table holds data relating to a specific cryptographic authentication method which is enrolled against an authenticator.
-- @field [AUTH_METHOD_ID]: The identifier for this authentication method. Values are a generated UUID. A foreign key to the AUTH_METHOD_ID of the REGISTERED_AUTH_METHODS table.
-- @field [SUBTYPE]: The sub-type of this authentication method. Will be one of either 'fingerprint' or 'user_presence'.
-- @field [ALGORITHM]: The algorithm used to create the cryptographic key pair for this authentication method.
-- @field [PUBLIC_KEY]: The public key portion of the cryptographic key pair for this authentication method. Will be Base64 encoded.
-- @field [KEY_HANDLE]: The key handle of this authentication methods key pair.
-- @field [USE_COUNT]: The value that corresponds to the number of times this authentication method has been used.
CREATE TABLE CRYPTO_AUTH_METHODS (
       AUTH_METHOD_ID    VARCHAR(256)    NOT NULL,
       SUBTYPE           VARCHAR(64)     NOT NULL,
       ALGORITHM         VARCHAR(256)    NOT NULL,
       PUBLIC_KEY        TEXT            NOT NULL,
       KEY_HANDLE        VARCHAR(256),
       USE_COUNT         BIGINT,

       PRIMARY KEY (AUTH_METHOD_ID),
       FOREIGN KEY (AUTH_METHOD_ID) REFERENCES REGISTERED_AUTH_METHODS(AUTH_METHOD_ID) ON DELETE CASCADE
);


COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201605015.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201606027.sql"

-- @component: MMFA
-- @description: This table holds data relating to a MMFA authentication transaction.
--               Current indexes: (DATE_CREATED), (DATE_LAST_USED), (TENANT_ID), (USERNAME), (RESULT_STATE) PostgreSQL: btree(TXN_ID)
-- @field [TXN_ID]: The identifier field for this table. Values are a generated UUID. This field
--                  also acts as a primary key for the table.
-- @field [DATE_CREATED]: The creation date/time of this transaction.
-- @field [DATE_LAST_USED]: The last used date/time of this transaction. This field is updated any time any piece of this transactions associated data is updated.
-- @field [USERNAME]: The ISAM username of the user associated with this transaction.
-- @field [AUTHN_POLICY_URI]: The Policy URI of the authentication policy which initiated this transaction.
-- @field [REQUESTED_URL]: The originally requested URL that a user will be redirected to upon successful completion of the transaction.
-- @field [ACTION_ID]: The HTTP method to be used for interacting with this transaction. Always has the value "POST".
-- @field [RESULT_STATE]: The current state of the transaction. ('pending','success','fail','abort','canceled')
-- @field [TENANT_ID]: The name of the tenant that this transaction is associated with. Typically, will be 'amapp-runtime'.
CREATE TABLE MMFA_AUTH_TXN_DATA (
  TXN_ID            VARCHAR(256)  NOT NULL,
  DATE_CREATED      TIMESTAMP     NOT NULL,
  DATE_LAST_USED    TIMESTAMP     NOT NULL,
  USERNAME          VARCHAR(256)  NOT NULL,
  AUTHN_POLICY_URI  VARCHAR(200)  NOT NULL,
  REQUESTED_URL     VARCHAR(4000) NOT NULL,
  ACTION_ID         VARCHAR(200)  NOT NULL,
  RESULT_STATE      VARCHAR(50)   NOT NULL,
  TENANT_ID         VARCHAR(200),


  CONSTRAINT MMFA_TXID_PK  PRIMARY KEY (TXN_ID),
  CONSTRAINT MMFA_RESULT_VALS CHECK (RESULT_STATE IN ('pending', 'success', 'fail', 'abort', 'canceled'))
);

CREATE INDEX MMFA_AUTX_CREATED_TIME ON MMFA_AUTH_TXN_DATA(DATE_CREATED);
CREATE INDEX MMFA_AUTX_LASTUSED_TIME ON MMFA_AUTH_TXN_DATA(DATE_LAST_USED);


-- @component: MMFA
-- @description: This table holds data for each parameter associated with a MMFA authentication transaction.
--               Current indexes: PostgreSQL: (btree(TXN_ID))
-- @field [TXN_ID]: The identifier field of the transaction this parameter is associated with. Values are a generated UUID. A foreign key to the TXN_ID of the MMFA_AUTH_TXN_DATA table.
-- @field [MMFA_PARAM_NAME]: The name of this parameter which is associated with a MMFA transaction.
-- @field [MMFA_PARAM_VALUE]: The value of this parameter which is associated with a MMFA transaction.
-- @field [MMFA_PARAM_DATATYPE]: The datatype of this parameter which is associated with a MMFA transaction. ('String','Double','Date','Time','Integer','X500Name','Boolean')
CREATE TABLE MMFA_AUTH_TXN_PARAMETERS_DATA (
  TXN_ID               VARCHAR(256)  NOT NULL,
  MMFA_PARAM_NAME      VARCHAR(200)  NOT NULL,
  MMFA_PARAM_VALUE     VARCHAR(2000) NOT NULL,
  MMFA_PARAM_DATATYPE  VARCHAR(200)  NOT NULL,

  CONSTRAINT MMFA_TXPID_PK  PRIMARY KEY (TXN_ID, MMFA_PARAM_NAME),
  CONSTRAINT MMFA_TXOV_FK1 FOREIGN KEY (TXN_ID) REFERENCES MMFA_AUTH_TXN_DATA(TXN_ID) ON DELETE CASCADE,
  CONSTRAINT MMFA_PA_DATATYPE CHECK (MMFA_PARAM_DATATYPE IN ('String', 'Double', 'Date', 'Time', 'Integer', 'X500Name', 'Boolean'))
);

CREATE INDEX mmfa_atopd_ix0 ON mmfa_auth_txn_parameters_data USING btree (txn_id);


-- @component: MMFA
-- @description: This table holds data for each context attribute that is associated with a MMFA transaction.
--               Current indexes: PostgreSQL: (btree(TXN_ID))
-- @field [TXN_ID]: The identifier field of the transaction this parameter is associated with. Values are a generated UUID. A foreign key to the TXN_ID of the MMFA_AUTH_TXN_DATA table.
-- @field [CTX_ATTR_NAME]: The name of this attribute which is associated with a MMFA transaction.
-- @field [CTX_ATTR_URI]: The ISAM URI for this attribute which is associated with a MMFA transaction.
-- @field [CTX_ATTR_ISSUER]: The issuer for this attribute which is associated with a MMFA transaction.
-- @field [CTX_ATTR_DATATYPE]: The datatype of this attribute which is associated with a MMFA transaction. ('String', 'Double', 'Date', 'Time', 'Integer', 'X500Name', 'Boolean')
-- @field [CTX_ATTR_VALUE_ID]: The identifier of the row for this context attributes value. Must be unique.
CREATE TABLE MMFA_AUTH_TXN_CTX_ATTRS_DATA (
  TXN_ID             VARCHAR(256) NOT NULL,
  CTX_ATTR_NAME      VARCHAR(200) NOT NULL,
  CTX_ATTR_URI       VARCHAR(200) NOT NULL,
  CTX_ATTR_ISSUER    VARCHAR(200),
  CTX_ATTR_DATATYPE  VARCHAR(200) NOT NULL,
  CTX_ATTR_VALUE_ID  VARCHAR(256) NOT NULL,

  CONSTRAINT MMFA_TXAID_PK  PRIMARY KEY (TXN_ID, CTX_ATTR_NAME, CTX_ATTR_URI),
  CONSTRAINT MMFA_TXOAV_FK1 FOREIGN KEY (TXN_ID) REFERENCES MMFA_AUTH_TXN_DATA(TXN_ID) ON DELETE CASCADE,
  CONSTRAINT MMFA_CA_DATATYPE CHECK (CTX_ATTR_DATATYPE IN ('String', 'Double', 'Date', 'Time', 'Integer', 'X500Name', 'Boolean')),
  CONSTRAINT MMFA_VID_UK1 UNIQUE  (CTX_ATTR_VALUE_ID)
);

CREATE INDEX mmfa_atocad_ix0 ON mmfa_auth_txn_ctx_attrs_data USING btree (txn_id);


-- @component: MMFA
-- @description: This table holds data for the value of each context attribute which is associated with a MMFA transaction.
--               Current indexes: PostgreSQL: (btree(CTX_ATTR_VALUE_ID)) DB2/Oracle: (CTX_ATTR_VALUE_ID)
-- @field [CTX_ATTR_VALUE_ID]: The identifier field of this context attribute value which is associated with a MMFA transaction. Values are a generated UUID. A foreign key to the CTX_ATTR_VALUE_ID of the MMFA_AUTH_TXN_CTX_ATTRS_DATA table.
-- @field [CTX_ATTR_VALUE]: The context attribute value which is associated with a MMFA transaction.
CREATE TABLE MMFA_AUTH_TXN_CTX_ATTRS_DATA_V (
 CTX_ATTR_VALUE_ID  VARCHAR(256)  NOT NULL,
 CTX_ATTR_VALUE     VARCHAR(2000) NOT NULL,

 CONSTRAINT MMFA_TXUAV_FK1 FOREIGN KEY (CTX_ATTR_VALUE_ID) REFERENCES MMFA_AUTH_TXN_CTX_ATTRS_DATA(CTX_ATTR_VALUE_ID) ON DELETE CASCADE
);

CREATE INDEX mmfa_atocadv_ix0 ON mmfa_auth_txn_ctx_attrs_data_v USING btree (ctx_attr_value_id);

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201606027.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201703170.sql"

-- @component: FIDO
-- @description: This table contains data for each FIDO U2F registration.
--               Current indexes: (USERNAME, TENANT_ID), (TENANT_ID)
-- @field [ID]: The identifier for this FIDO U2F registration. Values are a generated UUID.
-- @field [TENANT_ID]: The name of the tenant that this FIDO U2F registration is usable with. Typically, will be 'amapp-runtime'.
-- @field [USERNAME]: The ISAM username of the user associated with this FIDO U2F registration.
-- @field [ENABLED]: A boolean to represent if this registration is currently enabled.
-- @field [PUBLIC_KEY]: The public key portion of the key-pair generated by the U2F device at time of registration. Will be used to verify authentication requests.
-- @field [KEY_HANDLE]: A Base64 encoded key handle for this token.
-- @field [USAGE_COUNT]: The value that corresponds to the U2F authenticator device's internal counter.
-- @field [NAME]: The user defined display name of this U2F authenticator.
-- @field [APP_ID]: The U2F App ID of this token. Typically  a hostname, including protocol.
CREATE TABLE U2F_TOKENS (
       ID                VARCHAR(256)    NOT NULL,
       TENANT_ID         VARCHAR(256),
       USERNAME          VARCHAR(256)    NOT NULL,
       ENABLED           VARCHAR(64)     NOT NULL,
       PUBLIC_KEY        TEXT            NOT NULL,
       KEY_HANDLE        TEXT            NOT NULL,
       USAGE_COUNT       INT             NOT NULL,
       NAME              VARCHAR(256),
       APP_ID            VARCHAR(256)    NOT NULL,

       PRIMARY KEY (ID)
);


COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201703170.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201704050.sql"

CREATE INDEX AUTHENTICATOR_APP_INST_ID ON REGISTERED_AUTH_METHODS (APP_INST_ID);

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201704050.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201903140.sql"


-- @component: FIDO
-- @description: This table contains data for each FIDO2 registration.
--               Current indexes: (RP_ID, CREDENTIAL_ID), (RP_ID, USER_ID), (USERNAME), (U2FID), (TENANT_ID), (RP_ID), (AAGUID), (ENABLED)
-- @field [CREDENTIAL_ID]: The credential identifier for this FIDO2 registration. Values are a generated UUID.
-- @field [RP_ID]: The FIDO2 relying party ID this registration was made against. Typically a hostname.
-- @field [USER_ID]: The generated user identifier. Must be unable to determine anything about the user from the generated string. Will be stored on the FIDO2 authenticator along with credential.
-- @field [USERNAME]: The ISAM username of the user associated with this FIDO2 registration.
-- @field [TENANT_ID]: The name of the tenant that this FIDO2 registration is usable with. Typically, will be 'amapp-runtime'.
-- @field [NAME]: The user defined nickname of this FIDO2 registration.
-- @field [AAGUID]: The AAGUID of the authenticator device. Used to match a metadata file to an authenticator device. Is set on device by the authenticator manufacturer.
-- @field [PUBLIC_KEY]: The public key portion of the key-pair generated by the authenticator device at time of registration. Will be used to verify authenticity of authentication requests.
-- @field [TRUST_PATH_HASHES]: An array of hashed data which directly relates to the attestation generation if attestation was performed.
-- @field [FORMAT]: The format of the attestation at the time of registration.
-- @field [PRESENT]: The value of the user-present bit at the time of registration.
-- @field [VERIFIED]: The value of the user-verified bit at the time of registration.
-- @field [COUNT]: The value that corresponds to the authenticator devices internal counter.
-- @field [VERSION]: The version of the registration to indicate whether this was a U2F registration that has been migrated(1), or a WebAuthn FIDO2 registration(2).
-- @field [FUTURE]: Not currently in use, but allows for future changes to specification interfaces.
-- @field [ATTRIBUTES]: The attributes that were associated with the registration. Is stored as JSON Object.
-- @field [LAST_USED]: An ISO8601 formatted string which describes the last used date/time of this registration.
-- @field [CREATED]: An ISO8601 formatted string which describes the creation date/time of this registration.
-- @field [ATTESTATION_TYPE]: The type of the attestation at the time of registration.
-- @field [U2F_ID]: If this registration was migrated from U2F, this will be the U2F_ID of the migrated registration.
-- @field [U2F_APP_ID]: If this registration was migrated from U2F, this will be the U2F_APP_ID of the migrated registration.
-- @field [ENABLED]: A boolean to represent if this registration is currently enabled.

CREATE TABLE FIDO_AUTHENTICATORS (
       CREDENTIAL_ID     VARCHAR(2048)   NOT NULL,
       RP_ID             VARCHAR(256)    NOT NULL,
       USER_ID           VARCHAR(32)     NOT NULL,
       USERNAME          VARCHAR(256),
       TENANT_ID         VARCHAR(256),
       NAME              VARCHAR(256),
       AAGUID            VARCHAR(36),
       PUBLIC_KEY        TEXT            NOT NULL,
       TRUST_PATH_HASHES TEXT,
       FORMAT            VARCHAR(32),
       PRESENT           VARCHAR(5)      NOT NULL,
       VERIFIED          VARCHAR(5)      NOT NULL,
       COUNT             BIGINT          NOT NULL,
       VERSION           INT             NOT NULL,
       FUTURE            TEXT,
       ATTRIBUTES        TEXT,
       LAST_USED         BIGINT          NOT NULL,
       CREATED           BIGINT          NOT NULL,
       ATTESTATION_TYPE  VARCHAR(16)     NOT NULL,
       U2F_ID            VARCHAR(40),
       U2F_APP_ID        VARCHAR(256),
       ENABLED           VARCHAR(5)      NOT NULL,

       PRIMARY KEY  (CREDENTIAL_ID)
);


CREATE  INDEX FIDO_RPID_CREDID_INDEX ON FIDO_AUTHENTICATORS(RP_ID, CREDENTIAL_ID);
CREATE INDEX FIDO_RPID_USERID_INDEX ON FIDO_AUTHENTICATORS(RP_ID, USER_ID);
CREATE INDEX FIDO_USERNAME_INDEX ON FIDO_AUTHENTICATORS(USERNAME);
CREATE INDEX FIDO_U2F_ID_INDEX ON FIDO_AUTHENTICATORS(U2F_ID);

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201903140.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201910300.sql"

CREATE INDEX FIDO_RPID_INDEX ON FIDO_AUTHENTICATORS(RP_ID);
CREATE INDEX FIDO_AAGUID_INDEX ON FIDO_AUTHENTICATORS(AAGUID);
CREATE INDEX FIDO_ENABLED_INDEX ON FIDO_AUTHENTICATORS(ENABLED);

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201910300.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201903220.sql"

-- @component: FIDO
-- @description: This table contains data for each FIDO2 registration certificate which we store for attestation replay reasons.
-- @field [HANDLE]: The handle used for identification of this FIDO2 registration certificate. Primary Key for this table.
-- @field [CONTENTS]: The contents of the attestation certificate.
-- @field [TIMEOUT]: The timeout value for this attestation certificate to control how long lived this data is.
-- @field [CREATED]: The created date/time of this attestation certificate in ISO8601 format.
CREATE TABLE FIDO_ATTESTATION_CERTS (

       HANDLE   BIGINT      NOT NULL,
       CONTENTS TEXT        NOT NULL,
       TIMEOUT  BIGINT      NOT NULL,
       CREATED  BIGINT      NOT NULL,

       PRIMARY KEY (HANDLE)
);


COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201903220.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201911110.sql"

CREATE INDEX U2F_FOR_USER_IDX ON U2F_TOKENS(USERNAME, TENANT_ID);
CREATE INDEX U2F_ALL_USERS_IDX ON U2F_TOKENS(TENANT_ID);

CREATE INDEX AUTHN_TENANTID_IDX ON AUTHENTICATORS(TENANT_ID);
CREATE INDEX AUTHN_USERNAME_IDX ON AUTHENTICATORS(USERNAME);

CREATE INDEX FIDO_TENANTID_IDX ON FIDO_AUTHENTICATORS(TENANT_ID);

CREATE INDEX OAUTH_STATEID_IDX ON OAUTH_AUTHENTICATORS(STATE_ID);

CREATE INDEX MFA_TDATA_TENANTID_IDX ON MMFA_AUTH_TXN_DATA(TENANT_ID);
CREATE INDEX MFA_TDATA_USERNAME_IDX ON MMFA_AUTH_TXN_DATA(USERNAME);

CREATE INDEX MMFA_TDATA_ID_IDX ON MMFA_AUTH_TXN_DATA USING btree(TXN_ID);

CREATE INDEX MMFA_TDATA_RESULT_IDX ON MMFA_AUTH_TXN_DATA(RESULT_STATE);

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_201911110.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202010120.sql"

-- @component: PWD_VAULT 
-- @description: This table holds data for the password vault SPS.
-- @field [RGY_USERNAME]: Authenticated username
-- @field [RESOURCE_NAME]: Resource server which the credential is associated with
-- @field [USERNAME]: User which the crednetial is associated with
-- @field [PASSWORD]: Password; either a JWE or an unencrypted password
CREATE TABLE PWD_VAULT (
  RGY_USERNAME          VARCHAR(256) NOT NULL,
  RESOURCE_NAME         VARCHAR(256) NOT NULL,
  USERNAME              VARCHAR(256) NOT NULL,
  PASSWORD              TEXT NOT NULL,
  CONSTRAINT PWD_VAULT_PK PRIMARY KEY (RGY_USERNAME, RESOURCE_NAME)
);

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202010120.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202111030.sql"

CREATE INDEX MMFA_ATTRS_TXN_ID ON MMFA_AUTH_TXN_CTX_ATTRS_DATA(TXN_ID);

COMMIT;

-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202111030.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202305040.sql"

-- @component: FIDO
-- @description: This table contains the mappings between a USER ID and the related username and relying party ID.
--               Current indexes: (USER_ID), (RP_ID, USERNAME))
-- @field [USER_ID]: The generated user identifier. Must be unable to determine anything about the user from the generated string.
-- @field [USERNAME]: The username of the user associated with this USER_ID.
-- @field [RP_ID]: The FIDO2 relying party ID this USER_ID was generated for.
-- @field [TENANT_ID]: The name of the tenant that this USER_ID is usable with. Typically, will be 'amapp-runtime'.

CREATE TABLE FIDO_USER_IDS (
       USER_ID           VARCHAR(32)     NOT NULL,
       USERNAME          VARCHAR(256)    NOT NULL,
       RP_ID             VARCHAR(256)    NOT NULL,
       TENANT_ID         VARCHAR(256),

       PRIMARY KEY (USER_ID, USERNAME, RP_ID)
);


CREATE INDEX FIDO_RPID_USERNAME_INDEX ON FIDO_USER_IDS(RP_ID, USERNAME);
CREATE INDEX FIDO_USERID_INDEX ON FIDO_USER_IDS(USER_ID);

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202305040.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202402200.sql"

-- @component: FIDO
-- @description: This table contains data for each FIDO2 registration.
-- @field [ATTESTATION_OBJECT]: The Base64 URL encoded attestation object returned by an authenticator.
-- @field [CLIENT_DATA]: The Base64 URL encoded client data JSON generated by a client and signed by an authenticator.

ALTER TABLE FIDO_AUTHENTICATORS ADD ATTESTATION_OBJECT TEXT;
ALTER TABLE FIDO_AUTHENTICATORS ADD CLIENT_DATA TEXT;

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202402200.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202506310.sql"

-- @component: OAuth
-- @description: This table holds JWT ID claim.  This table is used for the IVIAOP component.
--               Current indexes: (EXPIRED_AT)
-- @field [JWT_TYPE]: The identifier for the type of JWT.
-- @field [JWT_ID]: The identifier for the JWT.
-- @field [EXPIRED_AT]: Expiry information.

CREATE TABLE OAUTH20_JTI (
	JWT_TYPE   INT          NOT NULL,
	JWT_ID     VARCHAR(256) NOT NULL,
	EXPIRED_AT BIGINT       NOT NULL,
	PRIMARY KEY(JWT_TYPE, JWT_ID)
);

CREATE INDEX IX_JTIS_EXPIRED ON OAUTH20_JTI(EXPIRED_AT);

-- @component: OAuth
-- @description: This table contains the authorization_details associated with an OAuth grant. This table is used for the IVIAOP component.
--               Current indexes: (USER_ID), (RP_ID, USERNAME))
-- @field [TRUSTED_CLIENT_ID]: The entry to store the decisions of a resource owner on which clients to trust.
-- @field [ID]: The ID representing the authorization_details.
-- @field [AUTHORIZATION_DETAILS]:The authorization_details.
-- @field [COMPARE_TYPE]: The various types of comparison of authorization_details.


CREATE TABLE OAUTH_AUTHORIZATION_DETAILS (
    TRUSTED_CLIENT_ID           VARCHAR(256)    NOT NULL,
    ID           				VARCHAR(256)    NOT NULL,
    AUTHORIZATION_DETAILS		TEXT,
    COMPARE_TYPE            	VARCHAR(256),
    PRIMARY KEY (TRUSTED_CLIENT_ID, ID),
    FOREIGN KEY (TRUSTED_CLIENT_ID) REFERENCES OAUTH_TRUSTED_CLIENT(TRUSTED_CLIENT_ID) ON DELETE CASCADE
);


-- @component: OAuth
-- @description: This table contains data for OAuth2.0 Token data.
-- @field [AUTHORIZATION_DETAILS]: The authorization_details associated with the token. 

ALTER TABLE OAUTH20_TOKEN_CACHE ADD AUTHORIZATION_DETAILS TEXT;

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202506310.sql"



ALTER TABLE USER_ATTRIBUTES_VALUES add primary key  (VALUES_ID, VALUE);




-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/AliasService.sql"


-- @component: Federation
-- @description: This table is used to store SAML2.0 identity mapping information. 
--               Current indexes: (ALIAS + PARTNER + ALIASTYPE + DOMAIN), (USERID + PARTNER + ALIASTYPE + DOMAIN)
-- @field [ALIAS]: The entry to store SAML2.0 identity mapping alias.
-- @field [USERID]: The entry to store user id.
-- @field [PARTNER]: The entry to store SAML2.0 partner id.
-- @field [ALIASTYPE]: The entry to store alias type.
-- @field [DOMAIN]: The entry to store the domain name.
-- @field [UUID]: The entry to store unique id for alias entry.
CREATE TABLE ALIAS_SVC_ALIASUSERPARTNER (
    ALIAS     	VARCHAR(256) NOT NULL,
    USERID    	VARCHAR(256) NOT NULL,
    PARTNER   	VARCHAR(256) NOT NULL,
    ALIASTYPE 	VARCHAR(256) NOT NULL,
    DOMAIN      VARCHAR(256) NOT NULL,
    UUID        VARCHAR(256),
    PRIMARY KEY  (ALIAS, USERID, PARTNER, ALIASTYPE, DOMAIN)
);

CREATE INDEX ALIAS_SVC_ALIAS_IX ON ALIAS_SVC_ALIASUSERPARTNER (ALIAS, PARTNER, ALIASTYPE, DOMAIN);
CREATE INDEX ALIAS_SVC_USERID_IX ON ALIAS_SVC_ALIASUSERPARTNER (USERID, PARTNER, ALIASTYPE, DOMAIN);


COMMIT;

-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/AliasService.sql"

-- This now needs to occur after the AliasService.sql
-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202432120.sql"

ALTER TABLE ALIAS_SVC_ALIASUSERPARTNER ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE AUTH_TXN_OBL_CTX_ATTRS_DATA ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE AUTH_TXN_OBL_CTX_ATTRS_DATA_V ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE AUTH_TXN_OBL_DATA ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE AUTH_TXN_OBL_PARAMETERS_DATA ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE AUTHENTICATORS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE CRYPTO_AUTH_METHODS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE DMAP_ENTRIES ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE FIDO_ATTESTATION_CERTS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE FIDO_AUTHENTICATORS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE FIDO_USER_IDS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE HVDB_SCHEMA_UPDATES ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE MMFA_AUTH_TXN_CTX_ATTRS_DATA ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE MMFA_AUTH_TXN_CTX_ATTRS_DATA_V ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE MMFA_AUTH_TXN_DATA ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE MMFA_AUTH_TXN_PARAMETERS_DATA ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE OAUTH20_DYNAMIC_CLIENT ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE OAUTH20_TOKEN_CACHE ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE OAUTH20_TOKEN_EXTRA_ATTRIBUTE ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE OAUTH_AUTHENTICATORS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE OAUTH_SCOPE ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE OAUTH_TRUSTED_CLIENT ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE PWD_VAULT ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE RBA_DEVICE ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE RBA_DEVICE_FINGERPRINT ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE RBA_RTE_DB_MAINTENANCE_META ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE RBA_USER_ATTR_SESSION ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE RBA_USER_ATTR_SESSION_DATA ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE RBA_USER_DEVICE ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE RBA_USER_USAGE_DATA ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE REGISTERED_AUTH_METHODS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE SCIM_EAS_EXT_METHODS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE SCIM_EAS_EXT_USERS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE U2F_TOKENS ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE USER_ATTRIBUTES ADD LAST_UPDATED_AT TIMESTAMP;
ALTER TABLE USER_ATTRIBUTES_VALUES ADD LAST_UPDATED_AT TIMESTAMP;


ALTER TABLE OAUTH20_TOKEN_EXTRA_ATTRIBUTE alter column STATE_ID set NOT NULL;
ALTER TABLE OAUTH20_TOKEN_EXTRA_ATTRIBUTE alter column ATTR_NAME set NOT NULL;
ALTER TABLE OAUTH20_TOKEN_EXTRA_ATTRIBUTE add primary key (STATE_ID, ATTR_NAME);


COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202432120.sql"

-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202512100.sql"

-- https://jsw.ibm.com/browse/ISVA-7573
-- Re-create the DMAP_ENTRIES with a inline expected length to improve performance
-- Postgresql does this automagically with TOAST, so we just try to pick the best storage alg.
-- MsSQL gives the option to store "large rows" inline with the table, or "out of row" somewhere else

-- https://www.postgresql.org/docs/current/storage-toast.html
ALTER TABLE DMAP_ENTRIES ALTER COLUMN DMAP_VALUE SET STORAGE EXTENDED;



-- Missing indexes on tables with cascade deletes
CREATE INDEX UAV_IX0 ON USER_ATTRIBUTES_VALUES(VALUES_ID); 
CREATE INDEX OTCID_IX0 ON OAUTH_AUTHORIZATION_DETAILS(TRUSTED_CLIENT_ID);


COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202512100.sql"

-- Start "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202512101.sql"

-- @component: OAuth
-- @description: This table contains data for OAuth2.0 Token data.
-- @field [SESSION_ID]: The session id of the user associated with the token. 

ALTER TABLE OAUTH20_TOKEN_CACHE ADD SESSION_ID VARCHAR(256);

COMMIT;
-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/FIM/upgrade/database/generic/hvdb/isam_access_control_generic_update_202512101.sql"

-- End "/tmp/mountrootfs247956.AJolKj/opt/ibm/generic/defs/hvdb/fim-hvdb.sql"
-- Start "/tmp/mountrootfs247956.AJolKj/opt/rtss/schema/generic/rtss-hvdb.sql"



-- End "/tmp/mountrootfs247956.AJolKj/opt/rtss/schema/generic/rtss-hvdb.sql"

-- End "/workspace/src/appliance/app-core/modules/files/hvdb.sql"
