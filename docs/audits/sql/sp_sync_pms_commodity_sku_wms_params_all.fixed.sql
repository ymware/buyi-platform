-- ============================================================================
-- SP2 修复 patch v2.1（2026-04-28）
-- 针对：sp_sync_pms_commodity_sku_wms_params_all
-- v2.1 变更：移除假想 amf_warehouse_map，改用真实链路
--   amf.warehouse_name → amf_warehouse_region.warehouse_code → wms_warehouse.name
--   外加 region→bucket 字典 CTE 兜底命名不一致的 FBM/CG-Litian 等
-- 详见：../AUDIT_PMS_SP_FIX_PATCH_20260428.md (v2.1 升级)
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- §0 三层归桶 CTE
-- ─────────────────────────────────────────────────────────────────────────
WITH
-- ① 店铺 → 桶（基础数据空洞：仅 5/11 桶有覆盖，另 6 桶空）
shop_to_bucket AS (
  SELECT r.shop_id, g.id AS logic_shop_id
  FROM cos_shop_group_relation r
  JOIN cos_shop_group g ON g.id = r.group_id AND g.group_type = 2
  WHERE r.deleted = 0 AND g.deleted = 0 AND g.company_id = p_company_id
),
-- ② 物理仓 → 桶（10/11，CA-OWS/MB 空）
warehouse_to_bucket AS (
  SELECT r.warehouse_id, wg.logic_shop_id
  FROM wms_warehouse_group_relation r
  JOIN wms_warehouse_group wg ON wg.id = r.warehouse_group_id AND wg.group_wms_type = 2
  WHERE r.is_delete = 0 AND wg.is_delete = 0 AND wg.company_id = p_company_id
),
-- ③ AMF 仓库代码 → wms_warehouse.id（27/29 直 JOIN 命中）
amf_to_wms AS (
  SELECT awr.warehouse_code AS amf_code, awr.region, w.id AS wms_warehouse_id
  FROM amf_warehouse_region awr
  LEFT JOIN wms_warehouse w
    ON w.name = awr.warehouse_code
   AND w.company_id = p_company_id AND w.is_delete = 0
),
-- ④ region 字符串 → 11 桶 logic_shop_id（兜底字典，处理 FBM/CG-Litian 命名不一致）
region_to_bucket AS (
  SELECT '美东' region, 1764655782335020001 logic_shop_id UNION ALL
  SELECT '美南',         1764655782335020002 UNION ALL
  SELECT '美西',         1764655782335020003 UNION ALL
  SELECT '美中',         1764655782335020004 UNION ALL
  SELECT '美北',         1764655782335020006 UNION ALL
  SELECT 'FBA',          1764655782335020005 UNION ALL
  SELECT 'FBM',          1764655782335020005 UNION ALL  -- FBM 暂归 US-FBA
  SELECT 'CG',           1764655782335020009 UNION ALL
  SELECT '欧洲',         1764655782335020010              -- LX欧洲仓→EU-OWS
),
-- ⑤ country_code → 桶（终极兜底）
country_to_bucket AS (
  SELECT 'US' cc, 1764655782335020005 logic_shop_id UNION ALL
  SELECT 'CA',     1764655782335020008 UNION ALL
  SELECT 'GB',     1764655782335020007 UNION ALL
  SELECT 'DE',     1764655782335020007 UNION ALL
  SELECT 'FR',     1764655782335020007 UNION ALL
  SELECT 'IT',     1764655782335020007 UNION ALL
  SELECT 'ES',     1764655782335020007 UNION ALL
  SELECT 'NL',     1764655782335020007 UNION ALL
  SELECT 'SE',     1764655782335020007 UNION ALL
  SELECT 'PL',     1764655782335020007 UNION ALL
  SELECT 'BE',     1764655782335020007
);


-- ─────────────────────────────────────────────────────────────────────────
-- §1 [P0-A 修复] 三源 UNION 库存 → 物理仓归桶
-- ─────────────────────────────────────────────────────────────────────────
DROP TEMPORARY TABLE IF EXISTS tmp_real_stock;
CREATE TEMPORARY TABLE tmp_real_stock AS
SELECT
  vw.warehouse_sku                                                                    AS sku,
  COALESCE(wb.logic_shop_id, rb.logic_shop_id, 1764655782335020005)                    AS logic_shop_id,
  SUM(vw.available_qty)                                                                AS qty
FROM v_amf_warehouse_stock vw
LEFT JOIN amf_to_wms          aw ON aw.amf_code        = vw.warehouse_name
LEFT JOIN warehouse_to_bucket wb ON wb.warehouse_id    = aw.wms_warehouse_id          -- ②真实归桶
LEFT JOIN region_to_bucket    rb ON rb.region          = vw.region                    -- ④region字典兜底
GROUP BY vw.warehouse_sku, COALESCE(wb.logic_shop_id, rb.logic_shop_id, 1764655782335020005);


-- ─────────────────────────────────────────────────────────────────────────
-- §2 [P0-B 修复] actual_stock / remaining 直从物理仓归桶（不再 cp×ratio）
-- ─────────────────────────────────────────────────────────────────────────
DROP TEMPORARY TABLE IF EXISTS tmp_actual_remaining;
CREATE TEMPORARY TABLE tmp_actual_remaining AS
SELECT
  jcs.local_sku                                                                       AS sku,
  COALESCE(wb.logic_shop_id, rb.logic_shop_id, 1764655782335020005)                    AS logic_shop_id,
  SUM(IFNULL(jcs.stock_num,0))                                                         AS actual_stock_qty,
  SUM(IFNULL(jcs.remaining_num,0) - IFNULL(jcs.stock_num,0))                           AS remaining_qty
FROM amf_jh_company_stock jcs
LEFT JOIN amf_to_wms          aw ON aw.amf_code        = jcs.warehouse_name
LEFT JOIN warehouse_to_bucket wb ON wb.warehouse_id    = aw.wms_warehouse_id
LEFT JOIN region_to_bucket    rb ON rb.region          = aw.region
WHERE jcs.local_sku IS NOT NULL
GROUP BY jcs.local_sku, COALESCE(wb.logic_shop_id, rb.logic_shop_id, 1764655782335020005);


-- ─────────────────────────────────────────────────────────────────────────
-- §3 [P0-C 修复] today_sale 直接从今日订单分桶
-- ─────────────────────────────────────────────────────────────────────────
DROP TEMPORARY TABLE IF EXISTS tmp_today_sale;
CREATE TEMPORARY TABLE tmp_today_sale AS
SELECT
  vo.warehouse_sku                                                                    AS sku,
  COALESCE(sb.logic_shop_id, wb.logic_shop_id, rb.logic_shop_id, cb.logic_shop_id, 1764655782335020005) AS logic_shop_id,
  SUM(vo.warehouse_sku_num)                                                            AS today_sale_qty
FROM v_amf_jh_lx_order vo
LEFT JOIN cos_shop            cs ON cs.shop_name      = vo.shop_name                  -- 店铺名→shop_id
LEFT JOIN shop_to_bucket      sb ON sb.shop_id        = cs.id                         -- ①店铺归桶
LEFT JOIN amf_to_wms          aw ON aw.amf_code       = vo.warehouse_name
LEFT JOIN warehouse_to_bucket wb ON wb.warehouse_id   = aw.wms_warehouse_id           -- ②仓库归桶
LEFT JOIN region_to_bucket    rb ON rb.region         = COALESCE(aw.region, vo.region)-- ④region字典
LEFT JOIN country_to_bucket   cb ON cb.cc             = vo.country_code               -- ⑤country兜底
WHERE DATE(vo.delivery_time) = p_monitor_date
GROUP BY vo.warehouse_sku,
         COALESCE(sb.logic_shop_id, wb.logic_shop_id, rb.logic_shop_id, cb.logic_shop_id, 1764655782335020005);


-- ─────────────────────────────────────────────────────────────────────────
-- §4 [P1-D / P1-E / P1-F 修复] 7天/30天销量改用视图字段，避免兜底 GREATEST
-- ─────────────────────────────────────────────────────────────────────────
DROP TEMPORARY TABLE IF EXISTS tmp_window_sale;
CREATE TEMPORARY TABLE tmp_window_sale AS
SELECT
  vo.warehouse_sku                                                                    AS sku,
  COALESCE(sb.logic_shop_id, wb.logic_shop_id, rb.logic_shop_id, cb.logic_shop_id, 1764655782335020005) AS logic_shop_id,
  SUM(CASE WHEN DATE(vo.delivery_time) >= DATE_SUB(p_monitor_date, INTERVAL 7  DAY)
            AND DATE(vo.delivery_time) <  p_monitor_date THEN vo.warehouse_sku_num END) AS seven_sale_qty,
  SUM(CASE WHEN DATE(vo.delivery_time) >= DATE_SUB(p_monitor_date, INTERVAL 30 DAY)
            AND DATE(vo.delivery_time) <  p_monitor_date THEN vo.warehouse_sku_num END) AS thirty_sale_qty
FROM v_amf_jh_lx_order vo
LEFT JOIN cos_shop            cs ON cs.shop_name      = vo.shop_name
LEFT JOIN shop_to_bucket      sb ON sb.shop_id        = cs.id
LEFT JOIN amf_to_wms          aw ON aw.amf_code       = vo.warehouse_name
LEFT JOIN warehouse_to_bucket wb ON wb.warehouse_id   = aw.wms_warehouse_id
LEFT JOIN region_to_bucket    rb ON rb.region         = COALESCE(aw.region, vo.region)
LEFT JOIN country_to_bucket   cb ON cb.cc             = vo.country_code
WHERE DATE(vo.delivery_time) >= DATE_SUB(p_monitor_date, INTERVAL 30 DAY)
  AND DATE(vo.delivery_time) <  p_monitor_date
GROUP BY vo.warehouse_sku,
         COALESCE(sb.logic_shop_id, wb.logic_shop_id, rb.logic_shop_id, cb.logic_shop_id, 1764655782335020005);


-- ─────────────────────────────────────────────────────────────────────────
-- §5 [P2-H 修复] FBA 不再二次乘 region_order_ratio
-- ─────────────────────────────────────────────────────────────────────────
-- 落盘：用四张 tmp 表 FULL OUTER JOIN（MySQL 用 UNION+GROUP BY 模拟）
-- INSERT INTO pms_commodity_sku_wms_params (
--   sku, mode_type, logic_shop_id, monitor_date,
--   actual_stock_qty, remaining_qty, today_sale_qty,
--   seven_sale_qty, thirty_sale_qty, platform_sale_num
-- ) SELECT … 略

-- ─────────────────────────────────────────────────────────────────────────
-- 验证 SQL（部署前应 dry-run）
-- ─────────────────────────────────────────────────────────────────────────
-- 1) 查归桶失败的订单（落到兜底桶 1764655782335020005 但 country 不是 US）
-- 2) 比对 SUM(SP1) vs SUM(SP2 fixed) 偏差应 <1%
-- 3) 比对 SUM(SP2 fixed by mode_type) vs v_amf_jh_lx_order 同期 SUM 应 ≈ 一致
