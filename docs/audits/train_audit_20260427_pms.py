"""追加 2026-04-27 PMS双表对账新发现到 Vanna 知识库"""
from app import build
vn = build()

docs = [
    """PMS双表口径终极结论 (2026-04-27 审计):
    pms_commodity_sku_params (产品总账) vs SUM(pms_commodity_sku_wms_params by mode_type) 6 字段对账:
    ✓ open_intransit_qty 完美一致 (152642=152642, 6143/6143 SKU 全 match) - 在途同步唯一可信链路
    ⚠ seven_sale_qty 24009 vs 23620 (+1.6%, 656 SKU 双向不一致) - mode_type=1美区按region_ratio小数分摊导致累加误差
    ❌ today_sale_qty 1689 vs 100 (+94%! mode_type=2-7全没算today, 只mode=1算了38)
    ❌ actual_stock_qty 45678 vs 19121 (+58%, 462 SKU 单向 params>SUM(wms_modes), wms 子集残缺)
    ❌ remaining_qty 145558 vs 51830 (+64%, 同 actual 因)
    ⚠ platform_sale_num 243287 vs 262019 (-7.7%, params 总账漏算了非主力渠道)""",

    """11 个 logic_shop_id 业务桶映射 (type=2 业务逻辑仓):
    1764655782335020001=美东, ...020002=美南, ...020003=美西, ...020004=美中
    ...020005=US-FBA, ...020006=美北(停用,ratio=0), ...020007=EU-FBA, ...020008=CA-FBA
    ...020009=CG, ...020010=EU-OWS, ...020011=CA-OWS
    pms_commodity_sku_wms_params 的 mode_type→logic_shop 映射:
    mode_type=1 → 美东/南/西/中/北(美区4桶+美北), mode_type=2→US-FBA, mode_type=3→CG
    mode_type=4→EU-FBA, mode_type=5→EU-OWS, mode_type=6→CA-FBA, mode_type=7→CA-OWS""",

    """根因分析 (2026-04-27 PMS BUG):
    R1·实物库存破洞: sp_sync_pms_commodity_sku_wms_params_all (LAST_ALTERED 2026-04-27 16:06)
       写库时漏抓了部分仓库实物库存; 462 SKU 在 11 桶里几乎全 0 (UK-GYG-WHITE 872→1, BO-YCG-ZXJXLG-WHITE 605→0)
    R2·today_sale 缺失: SP 只补 mode_type=1 的美区分摊 today, mode_type=2-7 的 today=0
       直接报废"实时备货决策"功能
    R3·销量小数分摊: mode_type=1 销量字段是 region_ratio 小数(.58/.82/.40/.20)
       与 params 总账整数累加四舍五入误差不可避免
    R4·platform_sale_num: params 漏算 channel=2/5/7/8/9/10/11 (TEMU/TikTok/鲸汇等)
       wms_params 端反而强行归到桶里, 出现 wms 多 18732""",
]
for d in docs:
    vn.train(documentation=d.strip())

audits = [
    ("PMS双表 6 字段总量对账", """
SELECT 'pms_total' src,
  SUM(seven_sale_qty) t7, SUM(thirty_sale_qty) t30, SUM(today_sale_qty) today,
  SUM(actual_stock_qty) act, SUM(remaining_qty) rem, SUM(open_intransit_qty) intr,
  SUM(platform_sale_num) plat
FROM pms_commodity_sku_params
WHERE company_id=local_company_id() AND monitor_date=CURDATE() AND deleted=0
UNION ALL
SELECT 'pms_wms_SUM', SUM(seven_sale_qty), SUM(thirty_sale_qty), SUM(today_sale_qty),
  SUM(actual_stock_qty), SUM(remaining_qty), SUM(open_intransit_qty), SUM(platform_sale_num)
FROM pms_commodity_sku_wms_params
WHERE company_id=local_company_id() AND monitor_date=CURDATE() AND deleted=0;
"""),
    ("PMS 双表 SKU 维度找出实物库存偏差最大 SKU", """
WITH pt AS (SELECT commodity_sku_id, commodity_sku_code, actual_stock_qty pa
            FROM pms_commodity_sku_params
            WHERE company_id=local_company_id() AND monitor_date=CURDATE() AND deleted=0),
     pw AS (SELECT commodity_sku_id, SUM(actual_stock_qty) wa
            FROM pms_commodity_sku_wms_params
            WHERE company_id=local_company_id() AND monitor_date=CURDATE() AND deleted=0
            GROUP BY commodity_sku_id)
SELECT pt.commodity_sku_code, pt.pa pms_act, pw.wa wms_sum_act, pt.pa-pw.wa diff
FROM pt JOIN pw USING(commodity_sku_id)
WHERE pt.pa <> pw.wa
ORDER BY ABS(pt.pa-pw.wa) DESC LIMIT 50;
"""),
    ("PMS wms_params 按 mode_type×logic_shop 分桶查看", """
SELECT mode_type,
  CASE logic_shop_id
    WHEN 1764655782335020001 THEN '美东'  WHEN 1764655782335020002 THEN '美南'
    WHEN 1764655782335020003 THEN '美西'  WHEN 1764655782335020004 THEN '美中'
    WHEN 1764655782335020005 THEN 'US-FBA' WHEN 1764655782335020006 THEN '美北'
    WHEN 1764655782335020007 THEN 'EU-FBA' WHEN 1764655782335020008 THEN 'CA-FBA'
    WHEN 1764655782335020009 THEN 'CG'    WHEN 1764655782335020010 THEN 'EU-OWS'
    WHEN 1764655782335020011 THEN 'CA-OWS' ELSE CONCAT('?',logic_shop_id) END bucket,
  COUNT(*) n,
  SUM(seven_sale_qty) t7, SUM(today_sale_qty) today,
  SUM(actual_stock_qty) act, SUM(platform_sale_num) plat
FROM pms_commodity_sku_wms_params
WHERE company_id=local_company_id() AND monitor_date=CURDATE() AND deleted=0
GROUP BY mode_type, logic_shop_id ORDER BY mode_type, n DESC;
"""),
    ("AMF→COS→PMS 三向销量真值对账", """
SELECT
  (SELECT SUM(quantity_ordered) FROM amf_jh_orders
   WHERE purchase_date >= DATE_SUB(CURDATE(), INTERVAL 7 DAY) AND purchase_date < CURDATE()+INTERVAL 1 DAY)
  + (SELECT SUM(it.quantity_ordered) FROM amf_lx_amzorder_item it JOIN amf_lx_amzorder o ON o.id=it.amzorder_id
     WHERE o.purchase_date >= DATE_SUB(CURDATE(), INTERVAL 7 DAY) AND o.purchase_date < CURDATE()+INTERVAL 1 DAY) AS amf_truth_7d,
  (SELECT SUM(seven_days_sale_num) FROM cos_goods_sku_sale
   WHERE company_id=local_company_id() AND end_date=CURDATE() AND deleted=0) AS cos_sale_7d,
  (SELECT SUM(seven_sale_qty) FROM cos_goods_sku_params
   WHERE company_id=local_company_id() AND monitor_date=CURDATE() AND deleted=0) AS cos_params_7d,
  (SELECT SUM(seven_sale_qty) FROM pms_commodity_sku_params
   WHERE company_id=local_company_id() AND monitor_date=CURDATE() AND deleted=0) AS pms_params_7d,
  (SELECT SUM(seven_sale_qty) FROM pms_commodity_sku_wms_params
   WHERE company_id=local_company_id() AND monitor_date=CURDATE() AND deleted=0) AS pms_wms_7d;
"""),
]
for q, sql in audits:
    vn.train(question=q, sql=sql.strip())

print(f"追加训练完成: {len(docs)} 文档 + {len(audits)} SQL")
df = vn.get_training_data()
print(f"现有总训练条数: {len(df)}")
