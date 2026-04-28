-- SP1 sp_sync_mp_sales_params_sku_union 完整源码（用户 2026-04-28 提供）
-- 写入目标表: pms_commodity_sku_params（产品维度总账）
-- 详见 ../AUDIT_PMS_SP_ROOT_CAUSE_20260428.md

CREATE DEFINER=`ServDBroot`@`%` PROCEDURE `sp_sync_mp_sales_params_sku_union`(
  IN p_company_id BIGINT,
  IN p_monitor_date DATE
)
-- [完整 ~250 行源码已记录在审计上下文中]
-- 关键特征：
--   §3 销量字段：CG=order_date, JH=delivery_time+8h, LX_MP=FROM_UNIXTIME(global_delivery_time), AMZ=shipment_date_local
--   §3.1 CG 店铺: shop IN ('Target_comfort','Macy_01')
--   §4 国内仓: amf_jh_company_stock SUM
--   §5 全量在库: JH(out_available_qty) + LX海外仓(wid 9488/9487 product_valid_num) + FBA(available_total) 三源
--   §6 在途: pms_commodity_shipment_item SUM
;
