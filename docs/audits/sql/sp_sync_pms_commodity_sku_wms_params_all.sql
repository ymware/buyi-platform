-- SP2 sp_sync_pms_commodity_sku_wms_params_all 完整源码（用户 2026-04-28 提供）
-- 写入目标表: pms_commodity_sku_wms_params（mode_type × logic_warehouse 分桶）
-- 详见 ../AUDIT_PMS_SP_ROOT_CAUSE_20260428.md

CREATE DEFINER=`ServDBroot`@`%` PROCEDURE `sp_sync_pms_commodity_sku_wms_params_all`(
  IN p_company_id BIGINT,
  IN p_monitor_date DATE
)
-- [完整 ~280 行源码已记录在审计上下文中]
-- 关键特征（与 SP1 不一致处即 8 处 BUG）：
--   §1 mode_type 映射: warehouse_code → 1-7 (FBA=2/EU-FBA=4/CA-FBA=6/CG=3/MX,MZ,MN,MD,MB=1/EU-OWS=5/CA-OWS=7)
--   §2 truth_total: 直接从 SP1 写好的 pms_commodity_sku_params 读
--   §3 销量权重 (BUG 来源):
--     CG: shop LIKE 'Target%' OR 'Macy%' OR 'BestBuy%', 排 'TEMU'  ← P1-E
--     JH: purchase_date+8h (vs SP1 用 delivery_time+8h)            ← P1-D
--     LX_MP: STR_TO_DATE(global_create_time) (vs SP1 FROM_UNIXTIME(global_delivery_time))  ← P1-D
--     AMZ: shipment_date_utc (vs SP1 shipment_date_local)          ← P1-D
--     全部 WHERE >= sub_30 AND < cur_start (不含今日)              ← P0-C
--   §4 final_dist: GREATEST(truth - sum_others, 0) 兜底吃负差      ← P1-F
--   §5 库存归桶: 仅 amf_lx_fbadetail，缺 JH仓 + LX海外仓 wid 9488/9487  ← P0-A / P0-G
--   落盘: actual_stock = cp.actual_stock_qty * region_order_ratio  ← P0-B
--         remaining = cp.remaining_qty * region_order_ratio        ← P0-B
--         FBA = rs.qty * region_order_ratio (二次乘 ratio)         ← P2-H
;
