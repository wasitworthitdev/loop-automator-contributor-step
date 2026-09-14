extends RefCounted
class_name LayerNames
## Names for the first layer of a new loop. A loop is named after its first
## layer, so instead of every new loop being "Layer 1" it gets a random name
## from the Bible; a name that is already in use gets a number after it
## ("Moses", then "Moses 2", "Moses 3"…).

const NAMES: PackedStringArray = [
	"Aaron", "Abel", "Abigail", "Abner", "Abraham", "Absalom", "Adam", "Amos", "Andrew",
	"Anna", "Apollos", "Aquila", "Asa", "Asaph", "Asher", "Balaam", "Barak", "Barnabas",
	"Bartholomew", "Baruch", "Bathsheba", "Benjamin", "Bezalel", "Boaz", "Caleb", "Cornelius",
	"Cyrus", "Dan", "Daniel", "Darius", "David", "Deborah", "Dinah", "Dorcas", "Eleazar",
	"Eli", "Elijah", "Elisha", "Elizabeth", "Enoch", "Ephraim", "Esau", "Esther", "Eve",
	"Ezekiel", "Ezra", "Gabriel", "Gad", "Gideon", "Habakkuk", "Haggai", "Hannah", "Hezekiah",
	"Hosea", "Huldah", "Isaac", "Isaiah", "Ishmael", "Issachar", "Jacob", "Jael", "Jairus",
	"James", "Japheth", "Jared", "Jehoshaphat", "Jephthah", "Jeremiah", "Jesse", "Jethro",
	"Joanna", "Job", "Joel", "John", "Jonah", "Jonathan", "Joseph", "Joshua", "Josiah",
	"Jude", "Judah", "Keturah", "Lazarus", "Leah", "Levi", "Lot", "Luke", "Lydia", "Malachi",
	"Manasseh", "Mark", "Martha", "Mary", "Matthew", "Matthias", "Melchizedek", "Micah",
	"Micaiah", "Michael", "Miriam", "Mordecai", "Moses", "Naaman", "Nahum", "Naomi",
	"Naphtali", "Nathan", "Nathanael", "Nehemiah", "Nicodemus", "Noah", "Obadiah", "Obed",
	"Onesimus", "Othniel", "Paul", "Peter", "Philemon", "Philip", "Phinehas", "Priscilla",
	"Rachel", "Rahab", "Rebekah", "Reuben", "Rhoda", "Ruth", "Salome", "Samson", "Samuel",
	"Sarah", "Seth", "Shadrach", "Shem", "Silas", "Simeon", "Simon", "Solomon", "Stephen",
	"Tabitha", "Tamar", "Thomas", "Timothy", "Titus", "Tychicus", "Uriah", "Uzziah", "Zacchaeus",
	"Zadok", "Zebulun", "Zechariah", "Zephaniah", "Zerubbabel", "Zipporah",
]


## A random name, numbered from 2 up if it is already in `taken`.
static func pick(taken: Array) -> String:
	var base := NAMES[randi() % NAMES.size()]
	if not (base in taken):
		return base
	var n := 2
	while "%s %d" % [base, n] in taken:
		n += 1
	return "%s %d" % [base, n]
