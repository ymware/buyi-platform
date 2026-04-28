-- ============================================================================
-- buyi_platform_dev 4 张权威真值视图 DDL（用户 2026-04-28 提供）
-- 这些视图是 PMS 双 SP 的"对账金标准"——任何归桶/拆分逻辑都必须以此为准
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- 1) v_amf_warehouse_stock —— 在库库存（FBA + JH仓 + LX欧洲仓 wid 9488/9487）
-- ─────────────────────────────────────────────────────────────────────────
CREATE ALGORITHM=UNDEFINED DEFINER=`buyi`@`%` SQL SECURITY DEFINER VIEW `v_amf_warehouse_stock` AS
SELECT
  amf_jh_warehouse_stock.warehouse_sku                AS warehouse_sku,
  amf_jh_warehouse_stock.warehouse_sku_name           AS warehouse_sku_name,
  COALESCE(amf_warehouse_region.region,'')            AS region,
  amf_jh_warehouse_stock.warehouse_name               AS warehouse_name,
  amf_jh_warehouse_stock.out_available_qty            AS available_qty,
  COALESCE(amf_spu_sku.spu, amf_jh_warehouse_stock.warehouse_sku) AS spu
FROM amf_jh_warehouse_stock
LEFT JOIN amf_warehouse_region ON amf_jh_warehouse_stock.warehouse_name = amf_warehouse_region.warehouse_code
LEFT JOIN amf_spu_sku ON amf_jh_warehouse_stock.warehouse_sku = amf_spu_sku.warehouse_sku AND amf_spu_sku.isdel = 0
WHERE amf_jh_warehouse_stock.out_available_qty <> 0
UNION ALL
SELECT
  amf_lx_warehouse_stock.sku                          AS warehouse_sku,
  COALESCE(amf_lx_products.product_name,'')           AS warehouse_sku_name,
  '欧洲'                                              AS region,
  CASE amf_lx_warehouse_stock.wid
    WHEN 9488 THEN '欧洲DE EUWE'
    WHEN 9487 THEN '欧洲UK UKNH02'
    ELSE '' END                                        AS warehouse_name,
  amf_lx_warehouse_stock.product_valid_num            AS available_qty,
  COALESCE(amf_spu_sku.spu, amf_lx_warehouse_stock.sku) AS spu
FROM amf_lx_warehouse_stock
LEFT JOIN amf_lx_products ON amf_lx_warehouse_stock.product_id = amf_lx_products.id
LEFT JOIN amf_spu_sku ON amf_lx_warehouse_stock.sku = amf_spu_sku.warehouse_sku AND amf_spu_sku.isdel = 0
WHERE amf_lx_warehouse_stock.wid IN (9488,9487) AND amf_lx_warehouse_stock.product_valid_num <> 0
UNION ALL
SELECT
  amf_lx_fbadetail.sku                                AS warehouse_sku,
  COALESCE(amf_lx_fbadetail.product_name,'')          AS warehouse_sku_name,
  'FBA'                                               AS region,
  amf_lx_fbadetail.name                               AS warehouse_name,
  amf_lx_fbadetail.available_total                    AS available_qty,
  COALESCE(amf_spu_sku.spu, amf_lx_fbadetail.sku)     AS spu
FROM amf_lx_fbadetail
LEFT JOIN amf_spu_sku ON amf_lx_fbadetail.sku = amf_spu_sku.warehouse_sku AND amf_spu_sku.isdel = 0
WHERE amf_lx_fbadetail.available_total <> 0 AND amf_lx_fbadetail.isdel = 0 AND amf_lx_fbadetail.sku <> '';


-- ─────────────────────────────────────────────────────────────────────────
-- 2) v_amf_jh_lx_order —— 销量订单（4 渠道 UNION ALL，定义所有"销量"字段权威口径）
-- ─────────────────────────────────────────────────────────────────────────
-- JH:    delivery_time+8h, order_status='FH', warehouse_sku NOT NULL, platform_name<>'小渠道'
-- LX_MP: from_unixtime(global_delivery_time), status=6, platform_code IN (10001,10002,10005,10031)
-- AMZ:   shipment_date_local, fulfillment_channel='AFN', item_order_status='Shipped'
-- CG:    order_date, shop LIKE 'Target%' OR 'Macy%' OR 'BestBuy%' OR (region=CG AND platform_name NOT IN ('TikTok','Walmart','ebay','TEMU'))
-- 完整 DDL 见 user 提供的视图源码（已收录在 vanna 训练集）


-- ─────────────────────────────────────────────────────────────────────────
-- 3) v_amf_onhand_stock —— 国内现货
-- ─────────────────────────────────────────────────────────────────────────
CREATE ALGORITHM=UNDEFINED DEFINER=`buyi`@`%` SQL SECURITY DEFINER VIEW `v_amf_onhand_stock` AS
SELECT
  amf_jh_company_stock.local_sku                              AS warehouse_sku,
  SUM(IFNULL(amf_jh_company_stock.stock_num,0))               AS stock_qty,
  SUM(IFNULL(amf_jh_company_stock.remaining_num,0) - IFNULL(amf_jh_company_stock.stock_num,0)) AS factory_qty,
  0                                                            AS isdel
FROM amf_jh_company_stock
WHERE amf_jh_company_stock.local_sku IS NOT NULL
GROUP BY amf_jh_company_stock.local_sku;
-- ⚠ 视图未对历史 sync_date 去重；SP1 用 ROW_NUMBER 取最新快照更精确


-- ─────────────────────────────────────────────────────────────────────────
-- 4) v_amf_onroad_stock —— 在途库存（JH发货 + LX FBA入库 + LX欧OWS入库）
-- ─────────────────────────────────────────────────────────────────────────
-- 完整 DDL 见 user 提供的视图源码（已收录在 vanna 训练集）
