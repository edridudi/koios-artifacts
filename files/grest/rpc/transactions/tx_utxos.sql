CREATE OR REPLACE FUNCTION grest.tx_utxos (_tx_hashes text[])
  RETURNS TABLE (
    tx_hash text,
    inputs jsonb,
    outputs jsonb
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _tx_hashes_bytea  bytea[];
  _tx_id_list       bigint[];
BEGIN
  -- convert input _tx_hashes array into bytea array
  SELECT INTO _tx_hashes_bytea ARRAY_AGG(hashes_bytea)
  FROM (
    SELECT
      DECODE(hashes_hex, 'hex') AS hashes_bytea
    FROM
      UNNEST(_tx_hashes) AS hashes_hex
  ) AS tmp;

  -- all tx ids
  SELECT INTO _tx_id_list ARRAY_AGG(id)
  FROM (
    SELECT
      id
    FROM 
      tx
    WHERE tx.hash = ANY (_tx_hashes_bytea)
  ) AS tmp;

  RETURN QUERY (
    WITH

      -- tx id / hash mapping
      _all_tx AS (
        SELECT
          tx.id AS tx_id,
          tx.hash AS tx_hash
        FROM
          tx
        WHERE tx.id = ANY (_tx_id_list)
      ),

      _all_inputs AS (
        SELECT
          tx_in.tx_in_id                      AS tx_id,
          tx_out.address                      AS payment_addr_bech32,
          ENCODE(tx_out.payment_cred, 'hex')  AS payment_addr_cred,
          SA.view                             AS stake_addr,
          ENCODE(tx.hash, 'hex')              AS tx_hash,
          tx_out.index                        AS tx_index,
          tx_out.value::text                  AS value,
          ( CASE WHEN MA.policy IS NULL THEN NULL
            ELSE
              JSONB_BUILD_OBJECT(
                'policy_id', ENCODE(MA.policy, 'hex'),
                'asset_name', ENCODE(MA.name, 'hex'),
                'fingerprint', MA.fingerprint,
                'decimals', aic.decimals,
                'quantity', MTO.quantity::text
              )
            END
          )                                   AS asset_list
        FROM
          tx_in
          INNER JOIN tx_out ON tx_out.tx_id = tx_in.tx_out_id
            AND tx_out.index = tx_in.tx_out_index
          INNER JOIN tx on tx_out.tx_id = tx.id
          LEFT JOIN stake_address SA ON tx_out.stake_address_id = SA.id
          LEFT JOIN ma_tx_out MTO ON MTO.tx_out_id = tx_out.id
          LEFT JOIN multi_asset MA ON MA.id = MTO.ident
          LEFT JOIN grest.asset_info_cache aic ON aic.asset_id = MA.id
        WHERE 
          tx_in.tx_in_id = ANY (_tx_id_list)
      ),

      _all_outputs AS (
        SELECT
          tx_out.tx_id,
          tx_out.address                      AS payment_addr_bech32,
          ENCODE(tx_out.payment_cred, 'hex')  AS payment_addr_cred,
          SA.view                             AS stake_addr,
          ENCODE(tx.hash, 'hex')              AS tx_hash,
          tx_out.index                        AS tx_index,
          tx_out.value::text                  AS value,
          ( CASE WHEN MA.policy IS NULL THEN NULL
            ELSE
              JSONB_BUILD_OBJECT(
                'policy_id', ENCODE(MA.policy, 'hex'),
                'asset_name', ENCODE(MA.name, 'hex'),
                'fingerprint', MA.fingerprint,
                'decimals', aic.decimals,
                'quantity', MTO.quantity::text
              )
            END
          )                                   AS asset_list
        FROM
          tx_out
          INNER JOIN tx ON tx_out.tx_id = tx.id
          LEFT JOIN stake_address SA ON tx_out.stake_address_id = SA.id
          LEFT JOIN ma_tx_out MTO ON MTO.tx_out_id = tx_out.id
          LEFT JOIN multi_asset MA ON MA.id = MTO.ident
          LEFT JOIN grest.asset_info_cache aic ON aic.asset_id = MA.id
        WHERE 
          tx_out.tx_id = ANY (_tx_id_list)
      )

    SELECT
      ENCODE(ATX.tx_hash, 'hex'),      
      COALESCE((
        SELECT JSONB_AGG(tx_inputs)
        FROM (
          SELECT
            JSONB_BUILD_OBJECT(
              'payment_addr', JSONB_BUILD_OBJECT(
                'bech32', payment_addr_bech32,
                'cred', payment_addr_cred
              ),
              'stake_addr', stake_addr,
              'tx_hash', AI.tx_hash,
              'tx_index', tx_index,
              'value', value,
              'asset_list', COALESCE(JSONB_AGG(asset_list) FILTER (WHERE asset_list IS NOT NULL), JSONB_BUILD_ARRAY())
            ) AS tx_inputs
          FROM _all_inputs AI
          WHERE AI.tx_id = ATX.tx_id
          GROUP BY payment_addr_bech32, payment_addr_cred, stake_addr, AI.tx_hash, tx_index, value
        ) AS tmp
      ), JSONB_BUILD_ARRAY()),
      COALESCE((
        SELECT JSONB_AGG(tx_outputs)
        FROM (
          SELECT
            JSONB_BUILD_OBJECT(
              'payment_addr', JSONB_BUILD_OBJECT(
                'bech32', payment_addr_bech32,
                'cred', payment_addr_cred
              ),
              'stake_addr', stake_addr,
              'tx_hash', AO.tx_hash,
              'tx_index', tx_index,
              'value', value,
              'asset_list', COALESCE(JSONB_AGG(asset_list) FILTER (WHERE asset_list IS NOT NULL), JSONB_BUILD_ARRAY())
            ) AS tx_outputs
          FROM _all_outputs AO
          WHERE AO.tx_id = ATX.tx_id
          GROUP BY payment_addr_bech32, payment_addr_cred, stake_addr, AO.tx_hash, tx_index, value
        ) AS tmp
      ), JSONB_BUILD_ARRAY())
    FROM
      _all_tx ATX
    WHERE ATX.tx_hash = ANY (_tx_hashes_bytea)
);

END;
$$;

COMMENT ON FUNCTION grest.tx_utxos IS 'Get UTXO set (inputs/outputs) of transactions.';

