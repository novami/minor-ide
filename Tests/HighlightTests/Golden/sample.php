<?php

declare(strict_types=1);

namespace App\Model;

use Nette\Database\Explorer;

/**
 * Repository of users.
 * @param int $id user ID
 */
#[Attribute(Attribute::TARGET_CLASS)]
final class UserRepository extends BaseRepository implements Countable, IteratorAggregate
{
	public const TABLE = 'users';

	public function __construct(
		private readonly Explorer $db,
	) {
	}

	public function find(int $id): ?array
	{
		$name = "User {$id}: $this->table\n";
		$sql = 'SELECT * FROM users
			WHERE id = ?'; // multi-line string
		$html = <<<HTML
			<b>$name</b> {$this->db->name}
			HTML;
		$raw = <<<'SQL'
			SELECT $notVar
			SQL;
		# hash comment
		return self::TABLE === static::class ? [0x1F, 1.5, true, null] : $this->db->table(self::TABLE)->fetch();
	}
}
?>
<div class="user <?= $cls ?>" data-id='5'>&amp; <!-- note
--> <?php echo htmlspecialchars($name) ?></div>
