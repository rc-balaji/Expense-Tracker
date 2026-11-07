import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

const membersSeed = ['Praveen', 'Mohan', 'Balaji', 'Kavi', 'Bala', 'Aravind'];
const categories = ['Food','Travel','Shopping','Groceries','Accommodation','Entertainment','Fuel','Bills','Medical','Other'];
const methods = ['Cash','UPI','Card','Bank Transfer','Other'];
final money = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
final dateFmt = DateFormat('dd MMM yyyy');
final uuid = Uuid();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = AppStore();
  await store.init();
  runApp(ChangeNotifierProvider.value(value: store, child: const SixTrackApp()));
}

class Member {
  final int id;
  final String name;
  final bool active;
  Member({required this.id, required this.name, required this.active});
  factory Member.fromMap(Map<String,dynamic> m) => Member(id:m['id'] as int,name:m['name'] as String,active:(m['active'] as int)==1);
  Map<String,dynamic> toMap() => {'id':id,'name':name,'active':active?1:0};
}

class Expense {
  final String id, title, payerId, category, note, method, splitType;
  final double amount;
  final DateTime date, createdAt, updatedAt;
  final Map<String,double> allocations;
  Expense({required this.id,required this.title,required this.amount,required this.payerId,required this.category,required this.date,required this.note,required this.method,required this.splitType,required this.allocations,required this.createdAt,required this.updatedAt});
  factory Expense.fromMap(Map<String,dynamic> m, List<Map<String,dynamic>> allocs) => Expense(
    id:m['id'], title:m['title'], amount:(m['amount'] as num).toDouble(), payerId:m['payer_id'].toString(),
    category:m['category'], date:DateTime.parse(m['date']), note:m['note']??'', method:m['method'], splitType:m['split_type'],
    allocations:{for(final a in allocs) a['member_id'].toString():(a['amount'] as num).toDouble()},
    createdAt:DateTime.parse(m['created_at']), updatedAt:DateTime.parse(m['updated_at']));
  Map<String,dynamic> toMap() => {'id':id,'title':title,'amount':amount,'payer_id':payerId,'category':category,'date':date.toIso8601String(),'note':note,'method':method,'split_type':splitType,'created_at':createdAt.toIso8601String(),'updated_at':updatedAt.toIso8601String()};
}

class Settlement {
  final String from, to;
  final double amount;
  Settlement(this.from,this.to,this.amount);
}

class AppStore extends ChangeNotifier {
  Database? _db;
  List<Member> members = [];
  List<Expense> expenses = [];
  bool dark = true;
  bool loading = false;
  Database get db => _db!;

  Future<void> init() async {
    final dir = await getDatabasesPath();
    _db = await openDatabase(p.join(dir,'sixtrack.db'),version:1,onCreate:(d,v) async {
      await d.execute('CREATE TABLE members(id INTEGER PRIMARY KEY, name TEXT NOT NULL, active INTEGER NOT NULL DEFAULT 1)');
      await d.execute('CREATE TABLE expenses(id TEXT PRIMARY KEY,title TEXT NOT NULL,amount REAL NOT NULL,payer_id TEXT NOT NULL,category TEXT NOT NULL,date TEXT NOT NULL,note TEXT,method TEXT NOT NULL,split_type TEXT NOT NULL,created_at TEXT NOT NULL,updated_at TEXT NOT NULL)');
      await d.execute('CREATE TABLE allocations(expense_id TEXT NOT NULL,member_id TEXT NOT NULL,amount REAL NOT NULL,PRIMARY KEY(expense_id,member_id),FOREIGN KEY(expense_id) REFERENCES expenses(id) ON DELETE CASCADE)');
      for(var i=0;i<membersSeed.length;i++){await d.insert('members',{'id':i+1,'name':membersSeed[i],'active':1});}
    });
    await refresh();
  }

  Future<void> refresh() async {
    loading=true; notifyListeners();
    members=(await db.query('members',orderBy:'id')).map(Member.fromMap).toList();
    final rows=await db.query('expenses',orderBy:'date DESC, created_at DESC');
    final list=<Expense>[];
    for(final r in rows){
      final a=await db.query('allocations',where:'expense_id=?',whereArgs:[r['id']]);
      list.add(Expense.fromMap(r,a));
    }
    expenses=list; loading=false; notifyListeners();
  }

  Future<void> saveMember(Member m) async { await db.update('members',m.toMap(),where:'id=?',whereArgs:[m.id]); await refresh(); }

  Future<void> saveExpense(Expense e,{bool isNew=true}) async {
    await db.transaction((txn) async {
      if(!isNew) await txn.delete('allocations',where:'expense_id=?',whereArgs:[e.id]);
      await txn.insert('expenses',e.toMap(),conflictAlgorithm:ConflictAlgorithm.replace);
      for(final entry in e.allocations.entries){
        await txn.insert('allocations',{'expense_id':e.id,'member_id':entry.key,'amount':entry.value});
      }
    });
    await refresh();
  }
  Future<void> deleteExpense(String id) async {
    await db.transaction((txn) async {await txn.delete('allocations',where:'expense_id=?',whereArgs:[id]); await txn.delete('expenses',where:'id=?',whereArgs:[id]);});
    await refresh();
  }

  double get total => expenses.fold(0,(s,e)=>s+e.amount);
  double get average => expenses.isEmpty?0:total/expenses.length;
  double get highest => expenses.isEmpty?0:expenses.map((e)=>e.amount).reduce(max);
  double get lowest => expenses.isEmpty?0:expenses.map((e)=>e.amount).reduce(min);
  double get todayTotal => expenses.where((e)=>DateUtils.isSameDay(e.date,DateTime.now())).fold(0,(s,e)=>s+e.amount);
  double get monthTotal => expenses.where((e)=>e.date.year==DateTime.now().year&&e.date.month==DateTime.now().month).fold(0,(s,e)=>s+e.amount);
  String memberName(String id) => members.where((m)=>m.id.toString()==id).map((m)=>m.name).firstOrNull ?? 'Unknown';

  Map<String,double> paidByMember() => {for(final m in members) m.id.toString():expenses.where((e)=>e.payerId==m.id.toString()).fold(0,(s,e)=>s+e.amount)};
  Map<String,double> allocatedByMember() => {for(final m in members) m.id.toString():expenses.fold(0,(s,e)=>s+(e.allocations[m.id.toString()]??0))};
  Map<String,double> netBalances() {
    final paid=paidByMember(), alloc=allocatedByMember();
    return {for(final m in members) m.id.toString():(paid[m.id.toString()]??0)-(alloc[m.id.toString()]??0)};
  }
  List<Settlement> settlements(){
    final balances=netBalances().entries.map((e)=>MapEntry(e.key,e.value)).toList();
    final creditors=balances.where((e)=>e.value>0.009).map((e)=>MapEntry(e.key,e.value)).toList();
    final debtors=balances.where((e)=>e.value< -0.009).map((e)=>MapEntry(e.key,-e.value)).toList();
    final result=<Settlement>[]; var i=0; var j=0;
    while(i<debtors.length&&j<creditors.length){
      final v=min(debtors[i].value,creditors[j].value);
      if(v>0.009) result.add(Settlement(debtors[i].key,creditors[j].key,v));
      debtors[i]=MapEntry(debtors[i].key,debtors[i].value-v);
      creditors[j]=MapEntry(creditors[j].key,creditors[j].value-v);
      if(debtors[i].value<0.009)i++; if(creditors[j].value<0.009)j++;
    }
    return result;
  }

  Future<String> exportJson() async {
    final data={'format':'sixtrack-backup-v1','members':members.map((m)=>m.toMap()).toList(),'expenses':expenses.map((e)=>e.toMap()).toList(),'allocations':expenses.map((e)=>{'expense_id':e.id,'items':e.allocations}).toList()};
    final dir=await getApplicationDocumentsDirectory();
    final f=File(p.join(dir.path,'sixtrack-backup-${DateTime.now().millisecondsSinceEpoch}.json'));
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    return f.path;
  }
  Future<void> importJson(String path) async {
    final data=jsonDecode(await File(path).readAsString()) as Map<String,dynamic>;
    if(data['format']!='sixtrack-backup-v1') throw Exception('Unsupported backup file');
    await db.transaction((txn) async {
      for(final m in (data['members'] as List)){await txn.insert('members',Map<String,dynamic>.from(m),conflictAlgorithm:ConflictAlgorithm.replace);}
      for(final raw in (data['expenses'] as List)){
        final e=Map<String,dynamic>.from(raw); await txn.insert('expenses',e,conflictAlgorithm:ConflictAlgorithm.replace);
      }
      for(final raw in (data['allocations'] as List)){
        final a=Map<String,dynamic>.from(raw);
        final items=Map<String,dynamic>.from(a['items']);
        await txn.delete('allocations',where:'expense_id=?',whereArgs:[a['expense_id']]);
        for(final entry in items.entries){await txn.insert('allocations',{'expense_id':a['expense_id'],'member_id':entry.key,'amount':entry.value});}
      }
    });
    await refresh();
  }
}

extension FirstOrNullExt<T> on Iterable<T> { T? get firstOrNull { final i=iterator; return i.moveNext()?i.current:null; } }

class SixTrackApp extends StatelessWidget {
  const SixTrackApp({super.key});
  @override Widget build(BuildContext context)=>Consumer<AppStore>(builder:(context,s,_)=>MaterialApp(
    debugShowCheckedModeBanner:false,title:'SIXTRACK',
    themeMode:s.dark?ThemeMode.dark:ThemeMode.light,
    theme:ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xff0e9f82),brightness:Brightness.light),scaffoldBackgroundColor:const Color(0xfff4f7f8),cardTheme:const CardThemeData(elevation:0,color:Colors.white,shape:RoundedRectangleBorder(borderRadius:BorderRadius.all(Radius.circular(18))))),
    darkTheme:ThemeData(useMaterial3:true,colorScheme:ColorScheme.fromSeed(seedColor:const Color(0xff39d6b0),brightness:Brightness.dark,surface:const Color(0xff111b22)),scaffoldBackgroundColor:const Color(0xff0a1117),cardTheme:const CardThemeData(elevation:0,color:Color(0xff121e26),shape:RoundedRectangleBorder(borderRadius:BorderRadius.all(Radius.circular(18))))),
    home:const HomeShell()));
}

class HomeShell extends StatefulWidget { const HomeShell({super.key}); @override State<HomeShell> createState()=>_HomeShellState(); }
class _HomeShellState extends State<HomeShell>{
  int index=0;
  final pages=const [DashboardPage(),ExpensesPage(),MembersPage(),ReportsPage(),SettingsPage()];
  @override Widget build(BuildContext context)=>Scaffold(
    body:SafeArea(child:IndexedStack(index:index,children:pages)),
    floatingActionButton:index==1||index==0?FloatingActionButton.extended(onPressed:()=>showExpenseEditor(context),icon:const Icon(Icons.add),label:const Text('Add expense')):null,
    bottomNavigationBar:NavigationBar(selectedIndex:index,onDestinationSelected:(v)=>setState(()=>index=v),destinations:const [
      NavigationDestination(icon:Icon(Icons.dashboard_outlined),selectedIcon:Icon(Icons.dashboard),label:'Home'),
      NavigationDestination(icon:Icon(Icons.receipt_long_outlined),selectedIcon:Icon(Icons.receipt_long),label:'Expenses'),
      NavigationDestination(icon:Icon(Icons.groups_outlined),selectedIcon:Icon(Icons.groups),label:'Members'),
      NavigationDestination(icon:Icon(Icons.analytics_outlined),selectedIcon:Icon(Icons.analytics),label:'Reports'),
      NavigationDestination(icon:Icon(Icons.settings_outlined),selectedIcon:Icon(Icons.settings),label:'Settings'),
    ]));
}

Widget pageHeader(String title,String subtitle,{Widget? trailing})=>Padding(padding:const EdgeInsets.fromLTRB(18,18,18,10),child:Row(children:[Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(title,style:const TextStyle(fontSize:25,fontWeight:FontWeight.w800)),Text(subtitle,style:TextStyle(color:Colors.grey.shade500,fontSize:12))])),if(trailing!=null)trailing]));
Widget sectionTitle(String s)=>Padding(padding:const EdgeInsets.fromLTRB(18,18,18,10),child:Text(s,style:const TextStyle(fontSize:16,fontWeight:FontWeight.w700)));
Widget kpi(String label,String value,IconData icon,{Color? color})=>Card(child:Padding(padding:const EdgeInsets.all(15),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Icon(icon,color:color??const Color(0xff39d6b0)),const SizedBox(height:12),Text(value,style:const TextStyle(fontSize:18,fontWeight:FontWeight.w800),maxLines:1,overflow:TextOverflow.ellipsis),const SizedBox(height:4),Text(label,style:TextStyle(color:Colors.grey.shade500,fontSize:11))])));
Widget memberChip(String name)=>Container(padding:const EdgeInsets.symmetric(horizontal:9,vertical:5),decoration:BoxDecoration(color:const Color(0xff39d6b0).withOpacity(.12),borderRadius:BorderRadius.circular(30)),child:Text(name,style:const TextStyle(fontSize:11,color:Color(0xff39d6b0),fontWeight:FontWeight.w600)));

class DashboardPage extends StatelessWidget { const DashboardPage({super.key});
@override Widget build(BuildContext context)=>Consumer<AppStore>(builder:(context,s,_)=>RefreshIndicator(onRefresh:s.refresh,child:ListView(padding:EdgeInsets.zero,children:[
pageHeader('SIXTRACK','Group expense overview',trailing:IconButton(onPressed:s.refresh,icon:const Icon(Icons.refresh))),
Padding(padding:const EdgeInsets.symmetric(horizontal:14),child:GridView.count(shrinkWrap:true,physics:const NeverScrollableScrollPhysics(),crossAxisCount:2,childAspectRatio:1.65,children:[
kpi('Total expenses',money.format(s.total),Icons.account_balance_wallet),kpi('Transactions','${s.expenses.length}',Icons.receipt_long),kpi('Average expense',money.format(s.average),Icons.calculate),kpi('Highest expense',money.format(s.highest),Icons.trending_up),kpi('Lowest expense',money.format(s.lowest),Icons.trending_down),kpi('This month',money.format(s.monthTotal),Icons.calendar_month),kpi('Today',money.format(s.todayTotal),Icons.today),kpi('Active members','${s.members.where((m)=>m.active).length}/6',Icons.groups),
])),
sectionTitle('Monthly expense trend'),
Card(margin:const EdgeInsets.symmetric(horizontal:16),child:Padding(padding:const EdgeInsets.all(16),child:SizedBox(height:190,child:LineChart(LineChartData(
gridData:const FlGridData(show:true),titlesData:const FlTitlesData(leftTitles:AxisTitles(sideTitles:SideTitles(showTitles:true,reservedSize:38)),bottomTitles:AxisTitles(sideTitles:SideTitles(showTitles:true))),
borderData:FlBorderData(show:false),lineBarsData:[LineChartBarData(isCurved:true,barWidth:3,dotData:const FlDotData(show:false),spots:List.generate(6,(i){final month=DateTime.now().subtract(Duration(days:(5-i)*30));final value=s.expenses.where((e)=>e.date.year==month.year&&e.date.month==month.month).fold(0.0,(a,e)=>a+e.amount);return FlSpot(i.toDouble(),value);}))]
))))),
sectionTitle('Member-wise spending'),
...s.members.map((m){final v=s.paidByMember()[m.id.toString()]??0;return Padding(padding:const EdgeInsets.symmetric(horizontal:18,vertical:4),child:Column(children:[Row(children:[Expanded(child:Text(m.name)),Text(money.format(v),style:const TextStyle(fontWeight:FontWeight.w700))]),const SizedBox(height:6),LinearProgressIndicator(value:s.highest==0?0:(v/s.total).clamp(0,1),minHeight:7,borderRadius:BorderRadius.circular(8))]));}),
sectionTitle('Category breakdown'),
if(s.expenses.isEmpty) const EmptyState(text:'No expenses yet. Add your first transaction.')
else Card(margin:const EdgeInsets.symmetric(horizontal:16),child:Padding(padding:const EdgeInsets.all(12),child:SizedBox(height:190,child:PieChart(PieChartData(sections:categories.map((c){final v=s.expenses.where((e)=>e.category==c).fold(0.0,(a,e)=>a+e.amount);return PieChartSectionData(value:v,title:v>0?c:'',radius:65,titleStyle:const TextStyle(fontSize:9,color:Colors.white));}).where((e)=>e.value>0).toList()))))),
sectionTitle('Recent transactions'),
...s.expenses.take(5).map((e)=>ExpenseTile(expense:e,onTap:()=>showExpenseDetails(context,e))),
const SizedBox(height:100)
])));}

class EmptyState extends StatelessWidget {final String text;const EmptyState({super.key,required this.text});@override Widget build(BuildContext context)=>Padding(padding:const EdgeInsets.all(35),child:Center(child:Column(children:[Icon(Icons.inbox_outlined,size:44,color:Colors.grey.shade500),const SizedBox(height:10),Text(text,textAlign:TextAlign.center,style:TextStyle(color:Colors.grey.shade500))])));}

class ExpenseTile extends StatelessWidget {final Expense expense;final VoidCallback onTap;const ExpenseTile({super.key,required this.expense,required this.onTap});@override Widget build(BuildContext context)=>Card(margin:const EdgeInsets.symmetric(horizontal:16,vertical:4),child:ListTile(onTap:onTap,leading:CircleAvatar(child:Icon(categoryIcon(expense.category))),title:Text(expense.title,style:const TextStyle(fontWeight:FontWeight.w700)),subtitle:Text('${expense.category} • ${dateFmt.format(expense.date)} • Paid by ${context.read<AppStore>().memberName(expense.payerId)}',maxLines:1,overflow:TextOverflow.ellipsis),trailing:Text(money.format(expense.amount),style:const TextStyle(fontWeight:FontWeight.w800))));}
IconData categoryIcon(String c)=>switch(c){'Food'=>Icons.restaurant,'Travel'=>Icons.directions_car,'Shopping'=>Icons.shopping_bag,'Groceries'=>Icons.local_grocery_store,'Accommodation'=>Icons.hotel,'Entertainment'=>Icons.movie,'Fuel'=>Icons.local_gas_station,'Bills'=>Icons.receipt,'Medical'=>Icons.medical_services,_=>Icons.more_horiz};

class ExpensesPage extends StatefulWidget {const ExpensesPage({super.key});@override State<ExpensesPage> createState()=>_ExpensesPageState();}
class _ExpensesPageState extends State<ExpensesPage>{
String query='',member='All',category='All',sort='Newest';DateTimeRange? range;double minAmount=0,maxAmount=10000000;
@override Widget build(BuildContext context)=>Consumer<AppStore>(builder:(context,s,_) {
var list=s.expenses.where((e){final q=query.toLowerCase();return (e.title.toLowerCase().contains(q)||e.note.toLowerCase().contains(q)||e.category.toLowerCase().contains(q))&&(member=='All'||e.payerId==member)&&(category=='All'||e.category==category)&&(range==null||(!e.date.isBefore(range!.start)&&!e.date.isAfter(range!.end.add(const Duration(days:1)))))&&e.amount>=minAmount&&e.amount<=maxAmount;}).toList();
if(sort=='Highest')list.sort((a,b)=>b.amount.compareTo(a.amount));else if(sort=='Lowest')list.sort((a,b)=>a.amount.compareTo(b.amount));else if(sort=='Oldest')list.sort((a,b)=>a.date.compareTo(b.date));else list.sort((a,b)=>b.date.compareTo(a.date));
return Column(children:[pageHeader('Expenses','Search, filter and manage every transaction'),Padding(padding:const EdgeInsets.symmetric(horizontal:16),child:TextField(onChanged:(v)=>setState(()=>query=v),decoration:const InputDecoration(prefixIcon:Icon(Icons.search),hintText:'Search expenses',border:OutlineInputBorder(),isDense:true))),
SingleChildScrollView(scrollDirection:Axis.horizontal,padding:const EdgeInsets.all(12),child:Row(children:[
_filterDrop('Payer',member,['All',...s.members.map((m)=>m.id.toString())],(v)=>setState(()=>member=v!),(v)=>v=='All'?'All':s.memberName(v)),
_filterDrop('Category',category,['All',...categories],(v)=>setState(()=>category=v!),(v)=>v),
_filterDrop('Sort',sort,['Newest','Oldest','Highest','Lowest'],(v)=>setState(()=>sort=v!),(v)=>v),
ActionChip(avatar:const Icon(Icons.date_range,size:17),label:Text(range==null?'Date range':'Date selected'),onPressed:()async{final r=await showDateRangePicker(context:context,firstDate:DateTime(2020),lastDate:DateTime.now().add(const Duration(days:365)));if(r!=null)setState(()=>range=r);}),
if(range!=null)ActionChip(label:const Text('Clear date'),onPressed:()=>setState(()=>range=null)),
])),
Padding(padding:const EdgeInsets.symmetric(horizontal:18,vertical:4),child:Row(children:[Expanded(child:Text('${list.length} transactions',style:TextStyle(color:Colors.grey.shade500))),Text(money.format(list.fold(0.0,(a,e)=>a+e.amount)),style:const TextStyle(fontWeight:FontWeight.w800))])),
Expanded(child:list.isEmpty?const EmptyState(text:'No matching expenses. Try clearing filters.'):ListView(children:list.map((e)=>ExpenseTile(expense:e,onTap:()=>showExpenseDetails(context,e))).toList())),
]);
});}

Widget _filterDrop(String label,String value,List<String> values,ValueChanged<String?> onChanged,String Function(String) display)=>Padding(padding:const EdgeInsets.only(right:6),child:DropdownButton<String>(value:value,items:values.map((v)=>DropdownMenuItem(value:v,child:Text(display(v)))).toList(),onChanged:onChanged,underline:const SizedBox(),hint:Text(label)));

class MembersPage extends StatelessWidget {const MembersPage({super.key});
@override Widget build(BuildContext context)=>Consumer<AppStore>(builder:(context,s,_)=>ListView(padding:EdgeInsets.zero,children:[
pageHeader('Members','Individual contribution and balances'),
...s.members.map((m){final paid=s.paidByMember()[m.id.toString()]??0;final alloc=s.allocatedByMember()[m.id.toString()]??0;final net=paid-alloc;final count=s.expenses.where((e)=>e.payerId==m.id.toString()||e.allocations.containsKey(m.id.toString())).length;return Card(margin:const EdgeInsets.symmetric(horizontal:16,vertical:6),child:ExpansionTile(leading:CircleAvatar(child:Text(m.name.isEmpty?'?':m.name[0])),title:Text(m.name,style:const TextStyle(fontWeight:FontWeight.w700)),subtitle:Text('${count} related transactions • ${m.active?'Active':'Inactive'}'),trailing:IconButton(icon:const Icon(Icons.edit_outlined),onPressed:()=>editMember(context,m)),childrenPadding:const EdgeInsets.fromLTRB(16,0,16,16),children:[
Row(children:[Expanded(child:kpi('Paid',money.format(paid),Icons.arrow_upward)),Expanded(child:kpi('Allocated',money.format(alloc),Icons.pie_chart)),Expanded(child:kpi('Net balance',money.format(net),Icons.account_balance))]),
Align(alignment:Alignment.centerLeft,child:Text(net>=0?'Owed to ${m.name}':'${m.name} owes',style:TextStyle(color:net>=0?Colors.green:Colors.orange))),
...s.expenses.where((e)=>e.payerId==m.id.toString()||e.allocations.containsKey(m.id.toString())).take(10).map((e)=>ExpenseTile(expense:e,onTap:()=>showExpenseDetails(context,e))),
]));}),
sectionTitle('Suggested settlements'),
...s.settlements().map((x)=>ListTile(leading:const Icon(Icons.swap_horiz),title:Text('${s.memberName(x.from)} → ${s.memberName(x.to)}'),trailing:Text(money.format(x.amount),style:const TextStyle(fontWeight:FontWeight.bold)))),
if(s.settlements().isEmpty)const EmptyState(text:'All member balances are settled.'),
const SizedBox(height:80)
]));}
Future<void> editMember(BuildContext context,Member m) async {
final c=TextEditingController(text:m.name);bool active=m.active;
await showDialog(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,set)=>AlertDialog(title:const Text('Edit member'),content:Column(mainAxisSize:MainAxisSize.min,children:[TextField(controller:c,decoration:const InputDecoration(labelText:'Member name')),SwitchListTile(title:const Text('Active'),value:active,onChanged:(v)=>set(()=>active=v))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('Cancel')),FilledButton(onPressed:()async{if(c.text.trim().isNotEmpty){await context.read<AppStore>().saveMember(Member(id:m.id,name:c.text.trim(),active:active));}if(ctx.mounted)Navigator.pop(ctx);},child:const Text('Save'))])));
}

}

class ReportsPage extends StatelessWidget {const ReportsPage({super.key});
@override Widget build(BuildContext context)=>Consumer<AppStore>(builder:(context,s,_)=>ListView(padding:EdgeInsets.zero,children:[
pageHeader('Reports','Export verified data from your local database'),
Card(margin:const EdgeInsets.symmetric(horizontal:16),child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
const Text('Group summary',style:TextStyle(fontSize:18,fontWeight:FontWeight.w800)),const SizedBox(height:12),
_reportRow('Total group expenses',money.format(s.total)),_reportRow('Transactions','${s.expenses.length}'),_reportRow('Average transaction',money.format(s.average)),_reportRow('This month',money.format(s.monthTotal)),_reportRow('Today',money.format(s.todayTotal)),
const SizedBox(height:16),SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:()=>generatePdf(context,s),icon:const Icon(Icons.picture_as_pdf),label:const Text('Generate full PDF report'))),
SizedBox(width:double.infinity,child:OutlinedButton.icon(onPressed:()=>generatePdf(context,s,share:true),icon:const Icon(Icons.share),label:const Text('Share PDF report'))),
]))),
sectionTitle('Member report'),
...s.members.map((m)=>ListTile(leading:const Icon(Icons.person_outline),title:Text(m.name),subtitle:Text('${s.expenses.where((e)=>e.payerId==m.id.toString()||e.allocations.containsKey(m.id.toString())).length} transactions'),trailing:IconButton(icon:const Icon(Icons.picture_as_pdf),onPressed:()=>generatePdf(context,s,memberId:m.id.toString())))),
sectionTitle('Settlement report'),
...s.settlements().map((x)=>_reportRow('${s.memberName(x.from)} pays ${s.memberName(x.to)}',money.format(x.amount))),
if(s.settlements().isEmpty)const Padding(padding:EdgeInsets.all(18),child:Text('No pending settlements.')),
const SizedBox(height:80)
]));}
Widget _reportRow(String a,String b)=>Padding(padding:const EdgeInsets.symmetric(vertical:7),child:Row(children:[Expanded(child:Text(a,style:TextStyle(color:Colors.grey.shade500))),Text(b,style:const TextStyle(fontWeight:FontWeight.w700))]));
}

class SettingsPage extends StatelessWidget {const SettingsPage({super.key});
@override Widget build(BuildContext context)=>Consumer<AppStore>(builder:(context,s,_)=>ListView(padding:EdgeInsets.zero,children:[
pageHeader('Settings','Preferences and data management'),
SwitchListTile(title:const Text('Dark theme'),subtitle:const Text('Use premium dark appearance'),value:s.dark,onChanged:(v){s.dark=v;s.notifyListeners();}),
ListTile(leading:const Icon(Icons.backup_outlined),title:const Text('Export JSON backup'),subtitle:const Text('Save all members, expenses and allocations'),onTap:()async{try{final path=await s.exportJson();await Share.shareXFiles([XFile(path)],text:'SIXTRACK data backup');}catch(e){if(context.mounted)showMsg(context,'Backup failed: $e');}}),
ListTile(leading:const Icon(Icons.restore),title:const Text('Import JSON backup'),subtitle:const Text('Restore records from a SIXTRACK backup'),onTap:()async{final result=await FilePicker.platform.pickFiles(type:FileType.custom,allowedExtensions:['json']);if(result?.files.single.path!=null){try{await s.importJson(result!.files.single.path!);if(context.mounted)showMsg(context,'Backup imported successfully');}catch(e){if(context.mounted)showMsg(context,'Import failed: $e');}}}),
ListTile(leading:const Icon(Icons.info_outline),title:const Text('About SIXTRACK'),subtitle:const Text('Version 1.0.0 • Offline group expense manager')),
ListTile(leading:const Icon(Icons.delete_forever,color:Colors.red),title:const Text('Clear all expenses',style:TextStyle(color:Colors.red)),subtitle:const Text('This action cannot be undone'),onTap:()async{final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Clear all expenses?'),content:const Text('All transactions and allocations will be permanently deleted. Members will remain.'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('Delete all'))]));if(ok==true){await s.db.delete('allocations');await s.db.delete('expenses');await s.refresh();if(context.mounted)showMsg(context,'All expenses deleted');}}),
const SizedBox(height:100)
]));}


Future<void> showExpenseEditor(BuildContext context, {Expense? existing, bool duplicate = false}) async {
  final store = context.read<AppStore>();
  final formKey = GlobalKey<FormState>();
  final title = TextEditingController(
    text: existing == null ? '' : (duplicate ? '${existing.title} (copy)' : existing.title),
  );
  final amount = TextEditingController(text: existing?.amount.toStringAsFixed(2) ?? '');
  final note = TextEditingController(text: existing?.note ?? '');
  String payer = existing?.payerId ?? store.members.first.id.toString();
  String category = existing?.category ?? categories.first;
  String method = existing?.method ?? methods.first;
  String split = existing?.splitType ?? 'Equal';
  DateTime date = existing?.date ?? DateTime.now();
  final selected = <String>{
    ...?existing?.allocations.keys,
    if (existing == null) ...store.members.where((m) => m.active).map((m) => m.id.toString()),
  };
  final custom = <String, TextEditingController>{
    for (final member in store.members)
      member.id.toString(): TextEditingController(
        text: existing?.allocations[member.id.toString()]?.toStringAsFixed(2) ?? '0',
      ),
  };

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) => Padding(
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 18,
          bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 18,
        ),
        child: Form(
          key: formKey,
          child: SizedBox(
            height: MediaQuery.of(sheetContext).size.height * .85,
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        existing == null ? 'Add expense' : (duplicate ? 'Duplicate expense' : 'Edit expense'),
                        style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Expanded(
                  child: ListView(
                    children: [
                      TextFormField(
                        controller: title,
                        decoration: const InputDecoration(labelText: 'Expense title', prefixIcon: Icon(Icons.edit)),
                        validator: (v) => v == null || v.trim().isEmpty ? 'Enter a title' : null,
                      ),
                      TextFormField(
                        controller: amount,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}'))],
                        decoration: const InputDecoration(labelText: 'Amount (₹)', prefixIcon: Icon(Icons.currency_rupee)),
                        validator: (v) => double.tryParse(v ?? '') == null || double.parse(v!) <= 0
                            ? 'Enter a valid amount'
                            : null,
                      ),
                      DropdownButtonFormField<String>(
                        value: payer,
                        decoration: const InputDecoration(labelText: 'Paid by'),
                        items: store.members.map((m) => DropdownMenuItem(value: m.id.toString(), child: Text(m.name))).toList(),
                        onChanged: (v) => setSheetState(() => payer = v!),
                      ),
                      DropdownButtonFormField<String>(
                        value: category,
                        decoration: const InputDecoration(labelText: 'Category'),
                        items: categories.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                        onChanged: (v) => setSheetState(() => category = v!),
                      ),
                      DropdownButtonFormField<String>(
                        value: method,
                        decoration: const InputDecoration(labelText: 'Payment method'),
                        items: methods.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                        onChanged: (v) => setSheetState(() => method = v!),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Expense date'),
                        subtitle: Text(dateFmt.format(date)),
                        trailing: const Icon(Icons.calendar_month),
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: sheetContext,
                            initialDate: date,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now().add(const Duration(days: 365)),
                          );
                          if (picked != null) setSheetState(() => date = picked);
                        },
                      ),
                      DropdownButtonFormField<String>(
                        value: split,
                        decoration: const InputDecoration(labelText: 'Split method'),
                        items: const ['Equal', 'Custom amount', 'Percentage']
                            .map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                        onChanged: (v) => setSheetState(() => split = v!),
                      ),
                      const SizedBox(height: 8),
                      const Text('Allocate expense to members', style: TextStyle(fontWeight: FontWeight.w700)),
                      ...store.members.map((member) {
                        final id = member.id.toString();
                        return Column(
                          children: [
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              value: selected.contains(id),
                              title: Text(member.name),
                              onChanged: (value) => setSheetState(() {
                                if (value == true) {
                                  selected.add(id);
                                } else {
                                  selected.remove(id);
                                }
                              }),
                            ),
                            if (selected.contains(id) && split != 'Equal')
                              Padding(
                                padding: const EdgeInsets.only(left: 45, right: 8),
                                child: TextFormField(
                                  controller: custom[id],
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: InputDecoration(
                                    labelText: split == 'Percentage' ? 'Percentage %' : 'Allocated amount ₹',
                                  ),
                                ),
                              ),
                          ],
                        );
                      }),
                      TextFormField(
                        controller: note,
                        maxLines: 2,
                        decoration: const InputDecoration(labelText: 'Notes (optional)', prefixIcon: Icon(Icons.notes)),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () async {
                      if (!formKey.currentState!.validate()) return;
                      final total = double.parse(amount.text);
                      if (selected.isEmpty) {
                        showMsg(context, 'Select at least one member');
                        return;
                      }
                      final allocations = <String, double>{};
                      if (split == 'Equal') {
                        final each = total / selected.length;
                        for (final id in selected) {
                          allocations[id] = each;
                        }
                        final last = selected.last;
                        allocations[last] = total - allocations.values.fold<double>(0, (a, b) => a + b) + allocations[last]!;
                      } else {
                        for (final id in selected) {
                          final value = double.tryParse(custom[id]!.text) ?? 0;
                          allocations[id] = split == 'Percentage' ? total * value / 100 : value;
                        }
                        final sum = allocations.values.fold<double>(0, (a, b) => a + b);
                        if ((sum - total).abs() > 0.01) {
                          showMsg(
                            context,
                            split == 'Percentage'
                                ? 'Percentages must total 100%.'
                                : 'Allocations must equal the expense amount.',
                          );
                          return;
                        }
                      }
                      final now = DateTime.now();
                      final expense = Expense(
                        id: existing != null && !duplicate ? existing.id : uuid.v4(),
                        title: title.text.trim(),
                        amount: total,
                        payerId: payer,
                        category: category,
                        date: date,
                        note: note.text.trim(),
                        method: method,
                        splitType: split,
                        allocations: allocations,
                        createdAt: existing?.createdAt ?? now,
                        updatedAt: now,
                      );
                      await store.saveExpense(expense, isNew: existing == null || duplicate);
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                      if (context.mounted) showMsg(context, 'Expense saved successfully');
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('Save expense'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  title.dispose();
  amount.dispose();
  note.dispose();
  for (final controller in custom.values) {
    controller.dispose();
  }
}

Future<void> showExpenseDetails(BuildContext context,Expense e) async {
final s=context.read<AppStore>();
await showModalBottomSheet(context:context,useSafeArea:true,builder:(ctx)=>Padding(padding:const EdgeInsets.all(20),child:Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
Text(e.title,style:const TextStyle(fontSize:22,fontWeight:FontWeight.w800)),Text(money.format(e.amount),style:const TextStyle(fontSize:25,fontWeight:FontWeight.w900,color:Color(0xff39d6b0))),
Text('${e.category} • ${dateFmt.format(e.date)}'),Text('Paid by ${s.memberName(e.payerId)} • ${e.method}'),if(e.note.isNotEmpty)Text(e.note),
const Divider(),const Text('Allocation',style:TextStyle(fontWeight:FontWeight.w700)),
...e.allocations.entries.map((a)=>ListTile(dense:true,title:Text(s.memberName(a.key)),trailing:Text(money.format(a.value)))),
Row(children:[TextButton.icon(onPressed:()async{Navigator.pop(ctx);await showExpenseEditor(context,existing:e,duplicate:true);},icon:const Icon(Icons.copy),label:const Text('Duplicate')),const Spacer(),TextButton.icon(onPressed:()async{Navigator.pop(ctx);await showExpenseEditor(context,existing:e);},icon:const Icon(Icons.edit),label:const Text('Edit')),IconButton(onPressed:()async{final ok=await showDialog<bool>(context:context,builder:(d)=>AlertDialog(title:const Text('Delete expense?'),content:const Text('This transaction will be permanently deleted.'),actions:[TextButton(onPressed:()=>Navigator.pop(d,false),child:const Text('Cancel')),FilledButton(onPressed:()=>Navigator.pop(d,true),child:const Text('Delete'))]));if(ok==true){await s.deleteExpense(e.id);if(ctx.mounted)Navigator.pop(ctx);}},icon:const Icon(Icons.delete_outline,color:Colors.red))])
])));
}


Future<void> generatePdf(
  BuildContext context,
  AppStore store, {
  String? memberId,
  bool share = false,
}) async {
  final data = memberId == null
      ? store.expenses
      : store.expenses.where((e) => e.payerId == memberId || e.allocations.containsKey(memberId)).toList();
  final total = data.fold<double>(0, (sum, expense) => sum + expense.amount);
  final document = pw.Document();

  document.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(32),
      footer: (ctx) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text('SIXTRACK • Confidential group report', style: const pw.TextStyle(fontSize: 8)),
          pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 8)),
        ],
      ),
      build: (ctx) => [
        pw.Text(
          'SIXTRACK',
          style: pw.TextStyle(fontSize: 27, fontWeight: pw.FontWeight.bold, color: PdfColor.fromHex('#087f68')),
        ),
        pw.Text(
          memberId == null ? 'Group Expense Report' : 'Member Expense Report • ${store.memberName(memberId)}',
          style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 5),
        pw.Text('Generated: ${DateFormat('dd MMM yyyy, hh:mm a').format(DateTime.now())}'),
        pw.SizedBox(height: 16),
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(color: PdfColor.fromHex('#e9f7f3')),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('TOTAL EXPENSES'),
                  pw.Text('₹ ${total.toStringAsFixed(2)}',
                      style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('TRANSACTIONS'),
                  pw.Text('${data.length}', style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
                ],
              ),
            ],
          ),
        ),
        pw.SizedBox(height: 18),
        pw.Text('Members', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Table.fromTextArray(
          headers: ['Member', 'Paid', 'Allocated', 'Net'],
          data: store.members.map((member) {
            final id = member.id.toString();
            final paid = data.where((e) => e.payerId == id).fold<double>(0, (a, e) => a + e.amount);
            final allocated = data.fold<double>(0, (a, e) => a + (e.allocations[id] ?? 0));
            return [member.name, paid.toStringAsFixed(2), allocated.toStringAsFixed(2), (paid - allocated).toStringAsFixed(2)];
          }).toList(),
        ),
        pw.SizedBox(height: 18),
        pw.Text('Transactions', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        pw.Table.fromTextArray(
          headers: ['Date', 'Title', 'Category', 'Paid by', 'Amount'],
          data: data.map((e) => [
            DateFormat('dd/MM/yy').format(e.date),
            e.title,
            e.category,
            store.memberName(e.payerId),
            e.amount.toStringAsFixed(2),
          ]).toList(),
          cellStyle: const pw.TextStyle(fontSize: 8),
          headerStyle: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 18),
        pw.Text('Settlement suggestions', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
        ...store.settlements().map(
          (settlement) => pw.Text(
            '${store.memberName(settlement.from)} pays ${store.memberName(settlement.to)}: ₹ ${settlement.amount.toStringAsFixed(2)}',
          ),
        ),
      ],
    ),
  );

  final bytes = await document.save();
  final directory = await getApplicationDocumentsDirectory();
  final file = File(p.join(directory.path, 'sixtrack-report-${DateTime.now().millisecondsSinceEpoch}.pdf'));
  await file.writeAsBytes(bytes);

  if (share) {
    await Share.shareXFiles([XFile(file.path)], text: 'SIXTRACK expense report');
  } else {
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }
  if (context.mounted) showMsg(context, 'PDF report generated');
}

void showMsg(BuildContext context,String msg)=>ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(msg)));
