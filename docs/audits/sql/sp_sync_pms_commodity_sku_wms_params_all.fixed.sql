-- ============================================================================
-- SP2 修复 patch（v2.0 终版 / 2026-04-28）
-- 针对：sp_sync_pms_commodity_sku_wms_params_all
-- 原则：以 v_amf_xxx 视图为真值；归桶以基础数据关系表(cos_shop_group / wms_warehouse_group)为优先
-- 详见：../AUDIT_PMS_SP_FIX_PATCH_20260428.md
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────
-- §0 新建桥接 CTE：三层归桶 logic_shop_id 解析
-- ─────────────────────────────────────────────────────────────────────────
-- 目标：给任意一笔订单/库存记录，确定其 logic_shop_id（11 个业务桶之一）
-- 优先级：①cos_shop_group(group_type=2) 店铺真实归属
--         ②wms_warehouse_group(group_wms_type=2) 物理仓真实归属
--         ③country_code/state 兜底规则（消除 SP2 当前的硬编码 BUG）
WITH
-- ① 店铺→桶（基础数据空洞：仅 5/11 桶有覆盖）
shop_to_bucket AS (
  SELECT r.shop_id, g.id AS logic_shop_id
  FROM cos_shop_group_relation r
  JOIN cos_shop_group g ON g.id = r.group_id AND g.group_type = 2
  WHERE r.deleted = 0 AND g.deleted = 0 AND g.company_id = p_company_id
),
-- ② 物理仓→桶（10/11 桶覆盖，CA-OWS/MB 缺）
warehouse_to_bucket AS (
  SELECT r.warehouse_id, wg.logic_shop_id
  FROM wms_warehouse_group_relation r
  JOIN wms_warehouse_group wg ON wg.id = r.warehouse_group_id AND wg.group_wms_type = 2
  WHERE r.is_delete = 0 AND wg.is_delete = 0 AND wg.company_id = p_company_id
),
-- ③ 兜底：country_code → bucket（SP2 当前唯一手段）
country_to_bucket AS (
  SELECT 'US' AS cc, 1764655782335020005 AS logic_shop_id  -- US-FBA
  UNION SELECT 'CA', 1764655782335020008                    -- CA-FBA
  UNION SELECT 'GB', 1764655782335020007 UNION SELECT 'DE', 1764655782335020007
  UNION SELECT 'FR', 1764655782335020007 UNION SELECT 'IT', 1764655782335020007
  UNION SELECT 'ES', 1764655782335020007 UNION SELECT 'NL', 1764655782335020007
  UNION SELECT 'SE', 1764655782335020007 UNION SELECT 'PL', 1764655782335020007
  UNION SELECT 'BE', 1764655782335020007                    -- EU-FBA
)


-- ─────────────────────────────────────────────────────────────────────────
-- §1 [P0-A 修复] 三源 UNION 库存：JH仓 + LX欧仓(wid 9488/9487) + FBA
-- ─────────────────────────────────────────────────────────────────────────
-- 直接复用 v_amf_warehouse_stock，按物理仓归桶（不再单纯看 country_code）
DROP TEMPORARY TABLE IF EXISTS tmp_real_stock;
CREATE TEMPORARY TABLE tmp_real_stock AS
SELECT
  vw.warehouse_sku                                                        AS sku,
  COALESCE(wb.logic_shop_id, cb.logic_shop_id, 1764655782335020005)        AS logic_shop_id,
  SUM(vw.available_qty)                                                    AS qty
FROM v_amf_warehouse_stock vw
LEFT JOIN amf_warehouse_map  am ON am.amf_warehouse_code = vw.warehouse_name        -- AMF→物理仓 ID
LEFT JOIN warehouse_to_bucket wb ON wb.warehouse_id = am.wms_warehouse_id            -- ②
LEFT JOIN country_to_bucket  cb ON cb.cc = vw.country_code                           -- ③兜底
GROUP BY vw.warehouse_sku, COALESCE(wb.logic_shop_id, cb.logic_shop_id, 1764655782335020005);


-- ─────────────────────────────────────────────────────────────────────────
-- §2 [P0-B 修复] actual_stock / remaining 不再 cp×ratio，从物理仓直归桶
-- ─────────────────────────────────────────────────────────────────────────
DROP TEMPORARY TABLE IF EXISTS tmp_actual_remaining;
CREATE TEMPORARY TABLE tmp_actual_remaining AS
SELECT
  vh.warehouse_sku                                                         AS sku,
  COALESCE(wb.logic_shop_id, 1764655782335020005)                           AS logic_shop_id,
  SUM(IFNULL(jcs.stock_num,0))                                              AS actual_stock_qty,
  SUM(IFNULL(jcs.remaining_num,0) - IFNULL(jcs.stock_num,0))                AS remaining_qty
FROM v_amf_onhand_stock vh
JOIN amf_jh_company_stock jcs ON jcs.local_sku = vh.warehouse_sku
LEFT JOIN amf_warehouse_map  am ON am.amf_warehouse_code = jcs.warehouse_name
LEFT JOIN warehouse_to_bucket wb ON wb.warehouse_id = am.wms_warehouse_id
WHERE jcs.local_sku IS NOT NULL
GROUP BY vh.warehouse_sku, COALESCE(wb.logic_shop_id, 1764655782335020005);


-- ─────────────────────────────────────────────────────────────────────────
-- §3 [P0-C 修复] today_sale 直接从今日订单分桶，不再用 30 天权重拆
-- ─────────────────────────────────────────────────────────────────────────
DROP TEMPORARY TABLE IF EXISTS tmp_today_sale;
CREATE TEMPORARY TABLE tmp_today_sale AS
SELECT
  vo.warehouse_sku                                                         AS sku,
  COALESCE(sb.logic_shop_id, wb.logic_shop_id, cb.logic_shop_id, 1764655782335020005) AS logic_shop_id,
  SUM(vo.warehouse_sku_num)                                                 AS today_sale_qty
FROM v_amf_jh_lx_order vo
LEFT JOIN cos_shop          cs ON cs.shop_name      = vo.shop_name
LEFT JOIN shop_to_bucket    sb ON sb.shop_id        = cs.id                         -- ①
LEFT JOIN amf_warehouse_map am ON am.amf_warehouse_code = vo.warehouse_name
LEFT JOIN warehouse_to_bucket wb ON wb.warehouse_id = am.wms_warehouse_id           -- ②
LEFT JOIN country_to_bucket cb ON cb.cc            = vo.country_code                -- ③
WHERE DATE(vo.delivery_time) = p_monitor_date
GROUP BY vo.warehouse_sku, COALESCE(sb.logic_shop_id, wb.logic_shop_id, cb.logic_shop_id, 1764655782335020005);


-- ─────────────────────────────────────────────────────────────────────────
-- §4 [P1-D / P1-E / P1-F 修复] 7天/30天销量改用视图字段，避免兜底 GREATEST
-- ─────────────────────────────────────────────────────────────────────────
-- 关键：SP2 §3 的 4 个 UNION 全部替换为直查 v_amf_jh_lx_order
-- 这样 JH 自动用 delivery_time+8h、LX 用 global_delivery_time、AMZ 用 shipment_date_local
-- CG 也会自然包含 BestBuy 系列店铺并排除 TEMU
DROP TEMPORARY TABLE IF EXISTS tmp_window_sale;
CREATE TEMPORARY TABLE tmp_window_sale AS
SELECT
  vo.warehouse_sku                                                         AS sku,
  COALESCE(sb.logic_shop_id, wb.logic_shop_id, cb.logic_shop_id, 1764655782335020005) AS logic_shop_id,
  SUM(CASE WHEN DATE(vo.delivery_time) >= DATE_SUB(p_monitor_date, INTERVAL 7  DAY)
            AND DATE(vo.delivery_time) <  p_monitor_date THEN vo.warehouse_sku_num END) AS seven_sale_qty,
  SUM(CASE WHEN DATE(vo.delivery_time) >= DATE_SUB(p_monitor_date, INTERVAL 30 DAY)
            AND DATE(vo.delivery_time) <  p_monitor_date THEN vo.warehouse_sku_num END) AS thirty_sale_qty
FROM v_amf_jh_lx_order vo
LEFT JOIN cos_shop          cs ON cs.shop_name      = vo.shop_name
LEFT JOIN shop_to_bucket    sb ON sb.shop_id        = cs.id
LEFT JOIN amf_warehouse_map am ON am.amf_warehouse_code = vo.warehouse_name
LEFT JOIN warehouse_to_bucket wb ON wb.warehouse_id = am.wms_warehouse_id
LEFT JOIN country_to_bucket cb ON cb.cc            = vo.country_code
WHERE DATE(vo.delivery_time) >= DATE_SUB(p_monitor_date, INTERVAL 30 DAY)
  AND DATE(vo.delivery_time) <  p_monitor_date
GROUP BY vo.warehouse_sku, COALESCE(sb.logic_shop_id, wb.logic_shop_id, cb.logic_shop_id, 1764655782335020005);


-- ─────────────────────────────────────────────────────────────────────────
-- §5 [P2-H 修复] FBA 库存归桶后不再二次乘 region_order_ratio
-- ─────────────────────────────────────────────────────────────────────────
-- 落盘逻辑：直接用 tmp_real_stock + tmp_actual_remaining + tmp_today_sale + tmp_window_sale
-- INSERT INTO pms_commodity_sku_wms_params (
--   sku, mode_type, logic_shop_id, monitor_date,
--   actual_stock_qty, remaining_qty, today_sale_qty,
--   seven_sale_qty, thirty_sale_qty, platform_sale_num
-- )
-- SELECT … 由四张 tmp 表 FULL OUTER JOIN 而成（MySQL 用 UNION+GROUP BY 模拟 FULL JOIN）

-- 备注：
--   如 amf_warehouse_map 不存在，需先建立 AMF 仓库代码 → wms_warehouse.id 的映射表
--   如 shop_to_bucket 仍有大量 NULL，则项目侧需补全 cos_shop_group_relation 基础数据
