"""追加 2026-04-28 4视图DDL+桶映射关系+SP升级审计 到 Vanna 知识库"""
from app import build
vn = build()

# ===== 4 张权威真值视图 DDL =====
ddls = [
    # v_amf_warehouse_stock 在库库存（FBA + JH仓 + LX欧洲仓 wid 9488/9487）
    """CREATE VIEW v_amf_warehouse_stock AS
SELECT warehouse_sku, warehouse_sku_name, region, warehouse_name, available_qty, spu
FROM ( amf_jh_warehouse_stock + amf_lx_warehouse_stock(wid IN 9488,9487) + amf_lx_fbadetail )
WHERE qty<>0 AND isdel=0;
-- 三源 UNION ALL: JH仓(out_available_qty) + LX欧洲海外仓(product_valid_num, wid=9488/9487) + FBA(available_total)""",
    # v_amf_jh_lx_order 销量订单视图（4 渠道 UNION）
    """CREATE VIEW v_amf_jh_lx_order AS
SELECT purchase_date, delivery_time, warehouse_sku, quantity_ordered, warehouse_name, region, platform_name, country_code, shop_name, order_no FROM
( amf_jh_orders(FH, 非小渠道, delivery_time+8h)
  UNION amf_lx_mporders(status=6, platform_code IN 10001/2/5/31, global_delivery_time)
  UNION amf_lx_amzorder(AFN, Shipped, shipment_date_local)
  UNION amf_jh_cgorders(shop LIKE Target%/Macy%/BestBuy% OR region=CG排除TikTok/Walmart/ebay/TEMU, order_date) );
-- 4 渠道权威销量口径""",
    # v_amf_onhand_stock 国内现货
    """CREATE VIEW v_amf_onhand_stock AS
SELECT local_sku, SUM(stock_num) stock_qty, SUM(remaining_num-stock_num) factory_qty FROM amf_jh_company_stock GROUP BY local_sku;
-- 注意视图未去重历史快照, SP1 实现用 ROW_NUMBER 取最新 sync_date 更精确""",
    # v_amf_onroad_stock 在途
    """CREATE VIEW v_amf_onroad_stock AS
SELECT warehouse_sku, ship_qty-receive_qty, warehouse_name, eta, arridate FROM
( amf_jh_shipment(status=0, shipment_date>=2025-08-01)
  UNION amf_lx_shipment(non-CANCELLED, is_closed=0, 6mo)
  UNION amf_lx_owmsshipment(status=50, real_delivery_time>=2025-08-01) );""",
]
for d in ddls:
    vn.train(ddl=d.strip())

# ===== 桶映射关系/基础数据空洞 重大事实 =====
docs = [
    """11个业务桶(wms_warehouse_group group_wms_type=2) 与 logic_shop_id 桥接(2026-04-28 验证):
wms_warehouse_group.logic_shop_id 100% = cos_shop_group.id (group_type=2)
11桶配比:
 美东MD ratio=0.27 / 美南MN 0.33 / 美西MX 0.30 / 美中MZ 0.10 / 美北MB 0.0(停)
 FBA 1.0 / 欧FBA 1.0 / 加FBA 1.0 / CG 1.0 / 欧OWS 1.0 / 加OWS 1.0
归桶链路两条:
 ①店铺归桶: shop_id → cos_shop_group_relation(deleted=0) → cos_shop_group(group_type=2,id=logic_shop_id)
 ②仓库归桶: warehouse_id → wms_warehouse_group_relation(is_delete=0) → wms_warehouse_group(group_wms_type=2)""",

    """❌ 基础数据空洞重大问题(2026-04-28):
cos_shop_group_relation 对 group_type=2 的覆盖严重不全:
 ✓ 仅5桶有店铺挂载: FBA(26) 美西(25) 加FBA(10) 欧FBA(9) [美南挂在'美南'下0条]
 ❌ 6桶完全空: 美东/美南/美中/美北/CG/欧OWS/加OWS
wms_warehouse_group_relation 对 group_type=2 的覆盖较好(10/11):
 ✓ 10桶有仓: CA-FBA(20) FBA(42) EU-FBA(9) MD(4) MN(6) MX(9) MZ(4) CG(2) EU-OWS(2)
 ❌ CA-OWS, MB 空
含义: SP2 当前用 country_code 硬编码归桶并非懒惰, 而是被迫workaround, 因为基础数据 cos_shop_group_relation 提供不了'shop→美东/美西/CG'归属""",

    """SP1 vs SP2 对照权威视图 v_amf_jh_lx_order 销量字段口径(2026-04-28 升级版根因):
渠道 | 视图字段 | SP1 | SP2 | 谁对齐
JH | delivery_time+8h | delivery_time+8h ✓ | purchase_date+8h ✗ | SP1
LX_MP | global_delivery_time | global_delivery_time ✓ | global_create_time ✗ | SP1
AMZ | shipment_date_local | shipment_date_local ✓ | shipment_date_utc ✗ | SP1
CG店铺 | LIKE Target%/Macy%/BestBuy% +排除TEMU | IN ('Target_comfort','Macy_01') ✗ | LIKE+排除TEMU ✓ | SP2
重大修正: CG维度SP2才对齐视图, SP1漏抓BestBuy整批店铺+没排除TEMU""",

    """SP2修复方案 三层归桶(2026-04-28 终版):
①优先 cos_shop_group_relation: shop_id 有真实店铺组归属 → logic_shop_id → mode_type
②次选 wms_warehouse_group_relation: 物理仓 warehouse_id → 仓组 → mode_type (10/11 桶覆盖好)
③兜底 country_code/state 规则: US/MX/BR→FBA(2); CA→CA-FBA(6); EU→EU-FBA(4); LX欧→OWS(5/7)
其他 P0 必修:
 - SP2 §5 platform_sale_num 重写为 SP1 §5 三源 UNION (JH+LX欧+FBA), 按物理仓归桶不再 ratio 拆
 - SP2 actual_stock/remaining 从 amf_jh_company_stock 按物理仓→wms_warehouse_group 归桶, 不再 cp×ratio
 - SP2 today_sale 单独从今日订单按 mode_type 直接归集, 不要用30天权重拆
 - SP1 §3.1 CG 店铺扩展为 LIKE 'Target%' OR 'Macy%' OR 'BestBuy%' 对齐视图""",
]
for d in docs:
    vn.train(documentation=d.strip())

# ===== 实用 SQL 模板 =====
sqls = [
    {"question":"查 11 个业务桶(group_type=2)及配比",
     "sql":"""SELECT id,logic_shop_id,warehouse_code,warehouse_name,region_order_ratio
FROM wms_warehouse_group WHERE company_id=1574398357059801089 AND is_delete=0 AND group_wms_type=2
ORDER BY warehouse_code;"""},
    {"question":"查每个业务桶挂了多少店铺(检测基础数据空洞)",
     "sql":"""SELECT g.group_name bucket, COUNT(DISTINCT r.shop_id) shop_n
FROM cos_shop_group g LEFT JOIN cos_shop_group_relation r ON r.group_id=g.id AND r.deleted=0
WHERE g.company_id=1574398357059801089 AND g.deleted=0 AND g.group_type=2
GROUP BY g.group_name ORDER BY shop_n DESC;"""},
    {"question":"查每个业务桶挂了多少物理仓",
     "sql":"""SELECT g.warehouse_code bucket, COUNT(DISTINCT r.warehouse_id) wh_n
FROM wms_warehouse_group g LEFT JOIN wms_warehouse_group_relation r ON r.warehouse_group_id=g.id AND r.is_delete=0
WHERE g.company_id=1574398357059801089 AND g.is_delete=0 AND g.group_wms_type=2
GROUP BY g.warehouse_code ORDER BY wh_n DESC;"""},
    {"question":"按权威视图 v_amf_jh_lx_order 校对某日销量(JH/LX/AMZ/CG)",
     "sql":"""SELECT
 SUM(CASE WHEN platform_name<>'小渠道' AND warehouse_name NOT LIKE 'FBA%' THEN warehouse_sku_num END) jh_qty,
 SUM(CASE WHEN warehouse_name='FBA' THEN warehouse_sku_num END) fba_qty
FROM v_amf_jh_lx_order
WHERE delivery_time>=DATE_SUB(CURDATE(),INTERVAL 30 DAY) AND delivery_time<CURDATE();"""},
]
for q in sqls:
    vn.train(question=q["question"], sql=q["sql"].strip())

print(f"训练完成: ddl +{len(ddls)} doc +{len(docs)} sql +{len(sqls)} = +{len(ddls)+len(docs)+len(sqls)}")
