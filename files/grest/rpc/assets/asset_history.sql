CREATE OR REPLACE FUNCTION grest.asset_history (_asset_policy text, _asset_name text default '')
  RETURNS TABLE (
    policy_id text,
    asset_name text,
    fingerprint character varying,
    minting_txs jsonb[]
  )
  LANGUAGE PLPGSQL
  AS $$
DECLARE
  _asset_policy_decoded bytea;
  _asset_name_decoded bytea;
BEGIN

  SELECT DECODE(_asset_policy, 'hex') INTO _asset_policy_decoded;

  SELECT DECODE(
    CASE WHEN _asset_name IS NULL
      THEN ''
    ELSE
      _asset_name
    END,
    'hex'
  ) INTO _asset_name_decoded;

  RETURN QUERY
    SELECT
      _asset_policy,
      _asset_name,
      minting_data.fingerprint,
      ARRAY_AGG(
        JSONB_BUILD_OBJECT(
          'tx_hash', minting_data.tx_hash,
          'block_time', minting_data.block_time,
          'quantity', minting_data.quantity,
          'metadata', minting_data.metadata
        )
        ORDER BY minting_data.id DESC
      )
    FROM (
      SELECT
        ma.fingerprint,
        tx.id,
        ENCODE(tx.hash, 'hex') AS tx_hash,
        EXTRACT(epoch from b.time)::integer as block_time,
        mtm.quantity::text,
        ( CASE WHEN TM.key IS NULL THEN JSONB_BUILD_ARRAY()
          ELSE
            JSONB_AGG(
              JSONB_BUILD_OBJECT(
                'key', TM.key::text,
                'json', TM.json
              )
            ) 
          END
        ) AS metadata
      FROM
        ma_tx_mint mtm
        INNER JOIN multi_asset ma ON ma.id = mtm.ident
        INNER JOIN tx ON tx.id = MTM.tx_id
        INNER JOIN block b ON b.id = tx.block_id
        LEFT JOIN tx_metadata TM ON TM.tx_id = tx.id
      WHERE MA.policy = _asset_policy_decoded 
        AND MA.name = _asset_name_decoded
      GROUP BY
        ma.fingerprint,
        tx.id,
        b.time,
        mtm.quantity,
        TM.key
    ) minting_data
    GROUP BY
      minting_data.fingerprint;
END;
$$;

COMMENT ON FUNCTION grest.asset_history IS 'Get the mint/burn history of an asset';
